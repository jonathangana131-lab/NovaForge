import AgentDomain
#if DEBUG
import AgentPolicy
#endif
import SwiftData
import SwiftUI
import UIKit

#if DEBUG
/// Deterministic classified values for UI accessibility/layout qualification.
///
/// This fixture never decodes provider JSON, executes a tool, or enters a
/// Release build. Production activity continues to come only from the
/// canonical journal repository and the process-owned AgentSystem.
enum AgentCanonicalActivityA11yFixture {
    static let launchArgument = "--canonical-activity-a11y-demo"
    static let approvalPendingDefaultsKey =
        "novaForgeDebugCanonicalActivityApprovalPending"
    static let approvalRequestID = ApprovalRequestID(rawValue: uuid(900))
    static let approvalRunID = RunID(rawValue: uuid(901))
    static let approvalCallID = ToolCallID(rawValue: uuid(902))
    static let workspaceID = WorkspaceID(rawValue: uuid(903))
    static let exactTarget =
        "Sources/Accessibility/Deeply Nested/Canonical Activity/approval-demo-with-a-deliberately-long-name.swift"

    static func pendingItem(now: Date = Date()) ->
        AgentApprovalPromptCenter.PendingItem
    {
        AgentApprovalPromptCenter.PendingItem(
            requestID: approvalRequestID,
            runID: approvalRunID,
            callID: approvalCallID,
            workspaceID: workspaceID,
            origin: .agentV2,
            toolTitle: "Write one reviewed file",
            toolName: "write_file",
            toolVersion: "2",
            effectClass: .scopedReversibleWrite,
            operation: .writeFile(
                path: exactTarget,
                contentUTF8ByteCount: 4_096
            ),
            previewSHA256: digest("a"),
            bindingSHA256: digest("b"),
            issuedAt: AgentInstant(now),
            expiresAt: AgentInstant(now.addingTimeInterval(10 * 60))
        )
    }

    static func groups(
        projectID: ProjectID?,
        conversationID: ConversationID,
        approvalPending: Bool
    ) -> [AgentActivityGroup] {
        let running = identity(
            runID: RunID(rawValue: uuid(910)),
            projectID: projectID,
            conversationID: conversationID
        )
        let failed = identity(
            runID: RunID(rawValue: uuid(920)),
            projectID: projectID,
            conversationID: conversationID
        )
        let approval = identity(
            runID: approvalRunID,
            projectID: projectID,
            conversationID: conversationID
        )

        return [
            runningGroup(identity: running),
            failedGroup(identity: failed),
            approvalGroup(identity: approval, isPending: approvalPending),
        ]
    }

    private static func runningGroup(
        identity: AgentActivityRunIdentity
    ) -> AgentActivityGroup {
        let items = (0 ..< 14).map { index in
            let isRunning = index == 13
            return item(
                id: .tool(ToolCallID(rawValue: uuid(1_000 + index))),
                kind: .tool,
                state: isRunning ? .running : .succeeded,
                summary: isRunning
                    ? "Verifying the compact canonical activity presentation at the largest accessibility text size"
                    : "Verified canonical activity checkpoint \(index + 1)",
                target: exactTarget,
                toolCallID: ToolCallID(rawValue: uuid(1_000 + index)),
                sequence: UInt64(index + 1),
                start: 1_800_000_100_000 + Int64(index * 400),
                duration: isRunning ? 1_900 : 320
            )
        }
        var attempts: [AgentActivityAttempt] = []
        attempts.reserveCapacity(6)
        for index in 0 ..< 6 {
            let attemptID = AttemptID(rawValue: uuid(1_100 + index))
            let retryOfAttemptID: AttemptID? = index == 0
                ? nil
                : AttemptID(rawValue: uuid(1_099 + index))
            let nextAttemptID: AttemptID? = index == 5
                ? nil
                : AttemptID(rawValue: uuid(1_101 + index))
            attempts.append(AgentActivityAttempt(
                id: attemptID,
                state: index == 5 ? .running : .failed,
                route: AgentActivityRoute(
                    provider: "classified-provider",
                    model: "classified-model",
                    adapter: "classified-adapter"
                ),
                span: span(
                    sequence: UInt64(30 + index),
                    start: 1_800_000_101_000 + Int64(index * 450),
                    duration: 420
                ),
                itemIDs: [],
                retryOfAttemptID: retryOfAttemptID,
                nextAttemptID: nextAttemptID,
                errorMessage: index == 5 ? nil : "A bounded retry was required."
            ))
        }
        return group(
            identity: identity,
            state: .running,
            summary: "Building and verifying the new compact activity experience",
            span: span(
                sequence: 1,
                start: 1_800_000_100_000,
                duration: 8_000
            ),
            items: items,
            attempts: attempts
        )
    }

    private static func failedGroup(
        identity: AgentActivityRunIdentity
    ) -> AgentActivityGroup {
        let failedAttempt = AttemptID(rawValue: uuid(1_200))
        let failure = "The verification receipt is incomplete; no workspace change was claimed."
        let items = [
            item(
                id: .tool(ToolCallID(rawValue: uuid(1_201))),
                kind: .tool,
                state: .succeeded,
                summary: "Inspected the accessibility fixture",
                target: exactTarget,
                toolCallID: ToolCallID(rawValue: uuid(1_201)),
                sequence: 1,
                start: 1_800_000_200_000,
                duration: 750
            ),
            item(
                id: .failure(EventID(rawValue: uuid(1_202))),
                kind: .failure,
                state: .failed,
                summary: "Verification needs attention",
                target: exactTarget,
                sequence: 2,
                start: 1_800_000_200_800,
                duration: 900,
                errorMessage: failure
            ),
        ]
        let artifacts = (0 ..< 4).map { index in
            let artifactID = ArtifactID(rawValue: uuid(1_220 + index))
            return AgentActivityArtifact(
                id: artifactID,
                run: identity,
                equivalentArtifactIDs: [artifactID],
                contentDigest: "sha256:fixture-artifact-\(index)",
                mediaType: "text/plain",
                displayName: "Canonical accessibility artifact \(index + 1).txt",
                firstSequence: EventSequence(rawValue: UInt64(10 + index)),
                sourceToolCallIDs: []
            )
        }
        return group(
            identity: identity,
            state: .failed,
            summary: "One verification step needs attention",
            span: span(
                sequence: 1,
                start: 1_800_000_200_000,
                duration: 2_500
            ),
            items: items,
            attempts: [
                AgentActivityAttempt(
                    id: failedAttempt,
                    state: .failed,
                    route: AgentActivityRoute(
                        provider: "classified-provider",
                        model: "classified-model",
                        adapter: "classified-adapter"
                    ),
                    span: span(
                        sequence: 3,
                        start: 1_800_000_200_000,
                        duration: 2_000
                    ),
                    itemIDs: items.map(\.id),
                    retryOfAttemptID: nil,
                    nextAttemptID: nil,
                    errorMessage: failure
                ),
            ],
            artifacts: artifacts,
            errorMessage: failure
        )
    }

    private static func approvalGroup(
        identity: AgentActivityRunIdentity,
        isPending: Bool
    ) -> AgentActivityGroup {
        let state: AgentActivityState = isPending ? .awaitingApproval : .rejected
        let requestedAt = AgentInstant(rawValue: 1_800_000_300_000)
        let action = item(
            id: .tool(approvalCallID),
            kind: .tool,
            state: state,
            summary: isPending
                ? "Write one reviewed accessibility fixture"
                : "Reviewed change was rejected without writing",
            target: exactTarget,
            toolCallID: approvalCallID,
            sequence: 1,
            start: requestedAt.rawValue,
            duration: 1_200
        )
        return group(
            identity: identity,
            state: state,
            summary: isPending
                ? "A workspace change is waiting for review"
                : "The reviewed workspace change was rejected",
            span: span(
                sequence: 1,
                start: requestedAt.rawValue,
                duration: 1_500
            ),
            items: [action],
            approvals: [
                AgentActivityApproval(
                    id: approvalRequestID,
                    run: identity,
                    callID: approvalCallID,
                    state: state,
                    publicSummary: "Review the exact target before writing one file.",
                    requestedAt: requestedAt,
                    resolvedAt: isPending
                        ? nil
                        : AgentInstant(rawValue: requestedAt.rawValue + 1_500)
                ),
            ]
        )
    }

    private static func identity(
        runID: RunID,
        projectID: ProjectID?,
        conversationID: ConversationID
    ) -> AgentActivityRunIdentity {
        AgentActivityRunIdentity(
            projectID: projectID,
            conversationID: conversationID,
            workspaceID: workspaceID,
            runID: runID,
            rootRunID: runID
        )
    }

    private static func group(
        identity: AgentActivityRunIdentity,
        state: AgentActivityState,
        summary: String,
        span: AgentActivityEventSpan,
        items: [AgentActivityItem],
        attempts: [AgentActivityAttempt] = [],
        approvals: [AgentActivityApproval] = [],
        artifacts: [AgentActivityArtifact] = [],
        errorMessage: String? = nil
    ) -> AgentActivityGroup {
        let sequences = items.map { $0.span.firstSequence }
        return AgentActivityGroup(
            identity: identity,
            state: state,
            summary: summary,
            span: span,
            items: items,
            attempts: attempts,
            approvals: approvals,
            artifacts: artifacts,
            evidence: [],
            errorMessage: errorMessage,
            replayIdentity: AgentActivityReplayIdentity(
                orderedEventIDs: items.enumerated().map {
                    EventID(rawValue: uuid(1_400 + $0.offset))
                },
                orderedSequences: sequences
            )
        )
    }

    private static func item(
        id: AgentActivityItemID,
        kind: AgentActivitySemanticKind,
        state: AgentActivityState,
        summary: String,
        target: String?,
        toolCallID: ToolCallID? = nil,
        sequence: UInt64,
        start: Int64,
        duration: Int64,
        errorMessage: String? = nil
    ) -> AgentActivityItem {
        AgentActivityItem(
            id: id,
            kind: kind,
            state: state,
            summary: summary,
            target: target,
            attemptID: nil,
            toolCallID: toolCallID,
            span: span(sequence: sequence, start: start, duration: duration),
            errorMessage: errorMessage,
            evidenceIDs: [],
            artifactIDs: []
        )
    }

    private static func span(
        sequence: UInt64,
        start: Int64,
        duration: Int64
    ) -> AgentActivityEventSpan {
        AgentActivityEventSpan(
            firstSequence: EventSequence(rawValue: sequence),
            lastSequence: EventSequence(rawValue: sequence),
            startedAt: AgentInstant(rawValue: start),
            endedAt: AgentInstant(rawValue: start + duration)
        )
    }

    private static func digest(_ digit: Character) -> SHA256Digest {
        try! SHA256Digest("sha256:" + String(repeating: digit, count: 64))
    }

    private static func uuid(_ value: Int) -> UUID {
        let suffix = String(format: "%012x", value)
        return UUID(uuidString: "00000000-0000-4000-8000-\(suffix)")!
    }
}

/// Adapts the deterministic simulator stress generator into the same
/// classified live-text snapshot consumed by production AgentSystem runs.
/// The retired runtime remains only the chunk clock for this DEBUG fixture;
/// the transcript still renders exclusively through the canonical
/// presentation contract and never reconstructs provider/tool payloads.
private enum AgentCanonicalStreamingPerformanceFixture {
    static let launchArgument = "--stress-streaming"
    static let runID = RunID(rawValue: uuid(1_500))
    static let attemptID = AttemptID(rawValue: uuid(1_501))
    static let isEnabled = ProcessInfo.processInfo.arguments.contains(
        launchArgument
    )

    @MainActor
    static func presentation(
        scope: AgentSystemPresentationScope,
        stream: LiveStreamBuffer,
        isWorking: Bool
    ) -> AgentSystemScopePresentation? {
        guard isEnabled else { return nil }
        let text = stream.displayText
        guard isWorking || !text.isEmpty else { return nil }
        let liveText = text.isEmpty ? nil : AgentSystemLiveTextSnapshot(
            runID: runID,
            attemptID: attemptID,
            revision: UInt64(max(0, stream.revision)),
            text: text
        )
        return AgentSystemScopePresentation(
            scope: scope,
            activeGroup: nil,
            liveText: liveText,
            isAccepting: false,
            isSynchronizing: false,
            failure: nil
        )
    }

    private static func uuid(_ value: Int) -> UUID {
        let suffix = String(format: "%012x", value)
        return UUID(uuidString: "00000000-0000-4000-8000-\(suffix)")!
    }
}
#endif

struct ChatView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    var runtime: AgentRuntime
    var hostedTextCanarySession: AgentHostedTextCanaryLiveSession
    var agentSystemPresentation: AgentSystemPresentationStore
    var project: Project
    var projects: [Project]
    var conversation: Conversation
    var conversations: [Conversation]
    var settings: AgentSettings
    let newChat: () -> Void
    let selectConversation: (Conversation) -> Void
    let deleteConversationFromHistory: (UUID) -> Void
    let setConversationProjectScope: (Conversation, Project?) -> Void
    var projectResumeDraft: String = ""
    var projectResumeDraftRevision: Int = 0
    let openWorkspaceSurface: (AppTab) -> Void
    let openArtifactLandscapeFullScreen: (WorkspaceArtifact) -> Void
    var isVisibleForFrameProfiling: Bool = true
    /// Live project-mission inputs for the Forge mission strip. The strip
    /// mirrors the active project's runtime so the tell → watch → approve
    /// loop stays on this one surface.
    var missionStatus: WorkspaceStatusSnapshot = .hidden
    var missionAutoContinue: ProjectAutoContinueViewState = .disabled
    /// True when the selected project chat itself owns the mission strip.
    /// When false, an active strip belongs to the background project runtime
    /// and this chat must not start a competing run in the same workspace.
    var missionUsesChatRuntime = false
    var approveMissionTool: () -> Void = {}
    var rejectMissionTool: () -> Void = {}
    var stopMissionRun: () -> Void = {}
    var pauseMissionAutoContinue: () -> Void = {}
    var openMissionDossier: () -> Void = {}
    var createProject: () -> Void = {}
    @State private var prompt = ""
    @State private var selectedArtifact: WorkspaceArtifact?
    @State private var chatSaveError: String?
    @State private var showingChatDrawer = false
    @State private var showingRunDetails = false
    @State private var messageRenderLimit = 80
    #if DEBUG
    @State private var debugSendDisposition = "idle"
    #endif
    @FocusState private var composerFocused: Bool
    @Namespace private var glassNamespace

    @State private var cachedMessages: [ChatMessageSnapshot] = []
    @State private var cachedActivityGroups: [AgentActivityGroup] = []
    @State private var canonicalActivityLoadFailed = false
    @State private var cachedSourceMessageCount = 0
    @State private var cachedArtifacts: [WorkspaceArtifact] = []
    @State private var cachedDurableRunSnapshot = ChatDurableRunSnapshot.empty
    @State private var cachedMissionContract: MissionOSContract?
    @State private var cachedWorkflowSpine: ProjectWorkflowSpine?
    @State private var forceScrollToBottom = false
    @State private var scrollAttachment: ChatScrollAttachment = .pinned
    @State private var jumpToLatestRequest = 0
    @State private var jumpToLatestAnimated = true
    @StateObject private var transient = ChatTransientState()
    @StateObject private var keyboard = ChatKeyboardState()
    @StateObject private var agentLiveStream = LiveStreamBuffer()
    @State private var agentLiveRunID: RunID?
    @State private var agentLiveAttemptID: AttemptID?
    @State private var agentLiveIngestedText = ""
    #if DEBUG
    @AppStorage(AgentCanonicalActivityA11yFixture.approvalPendingDefaultsKey)
    private var debugCanonicalActivityApprovalPending = false
    @State private var hostedTextCanaryDraftToken = UUID()
    @State private var lastHostedTextCanaryNoticeRevision: UInt64 = 0
    #endif
    @AppStorage("novaForgeChatDraftsByConversation") private var persistedDraftsJSON = "{}"

    private static let chatLatestAnchorID = "chatLatestAnchor"
    private static let chatBottomID = "chatBottom"
    private static let chatScrollSpace = "chatScroll"
    private let messageRenderWindowSize = 80
    private let bottomPinnedThreshold: CGFloat = 160
    private let detachedRepinThreshold: CGFloat = 28
    /// A growing response needs room for the run controls that join the dock.
    /// Once handoff completes, collapse that room immediately so the durable
    /// answer does not sit above a large invisible tail.
    private var latestResponseClearance: CGFloat {
        composerOwnsWorkingRun ? 32 : 28
    }

    private var shouldAnimateDecorative: Bool {
        AgentPerformance.allowsDecorativeMotion && !reduceMotion
    }

    private var hiddenMessageCount: Int {
        let visibleCount = min(cachedSourceMessageCount, messageRenderLimit)
        return max(conversation.messageCount - visibleCount, 0)
    }

    private var visibleMessages: ArraySlice<ChatMessageSnapshot> {
        guard messageRenderLimit > 0, cachedMessages.count > messageRenderLimit else {
            return cachedMessages[...]
        }
        return cachedMessages.suffix(messageRenderLimit)
    }

    private var activityGroupsForPresentation: [AgentActivityGroup] {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains(
            AgentCanonicalActivityA11yFixture.launchArgument
        ) {
            return AgentCanonicalActivityA11yFixture.groups(
                projectID: scopedProject.map { ProjectID(rawValue: $0.id) },
                conversationID: ConversationID(rawValue: conversation.id),
                approvalPending: debugCanonicalActivityApprovalPending
            )
        }
        #endif
        return cachedActivityGroups
    }

    private var transcriptRows: [ChatTranscriptRow] {
        let activityGroups = activityGroupsForPresentation
        let canonicalOwnsToolPresentation = !activityGroups.isEmpty ||
            canonicalActivityLoadFailed
        var rows = visibleMessages.compactMap { message -> ChatTranscriptRow? in
            // Once this exact conversation has canonical activity, the journal
            // owns tool presentation. Suppress legacy provider-call and tool
            // result bubbles instead of showing the same work twice (or
            // rebuilding it from untrusted JSON). User and final assistant
            // prose remain the primary transcript.
            if !ChatToolActivityCutoverPolicy.shouldRenderMessage(
                role: message.role,
                hasToolCalls: !message.toolCalls.isEmpty,
                canonicalOwnsToolPresentation: canonicalOwnsToolPresentation
            ) {
                return nil
            }
            return .message(message)
        }
        rows.append(contentsOf: activityGroups.map(ChatTranscriptRow.activity))
        if canonicalActivityLoadFailed {
            rows.append(.activityUnavailable(scopeID: evidenceScopeIdentity))
        }
        rows.sort(by: ChatTranscriptRow.precedes)
        guard shouldShowLiveResponseIsland else { return rows }
        guard let liveRunID = agentRunPresentation.liveText?.runID ??
                agentRunPresentation.activeGroup?.identity.runID
        else { return rows }

        // The durable assistant row owns handoff as soon as the exact RunID is
        // present. No timer or guessed message identity may clear the only
        // readable response.
        if rows.contains(where: {
            $0.assistantRunID == liveRunID.rawValue
        }) {
            return rows
        }
        rows.append(.live(runID: liveRunID))
        return rows
    }

    private var projectConversations: [Conversation] {
        let visibleConversations = ChatProjectSeparation.visibleChatConversations(from: conversations)
        let drawerConversations = visibleConversations.contains(where: { $0.id == conversation.id })
            ? visibleConversations
            : [conversation] + visibleConversations
        return drawerConversations.sorted { lhs, rhs in
            if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
            return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }
    }

    private var scopedProject: Project? {
        conversation.project
    }

    private var agentPresentationScope: AgentSystemPresentationScope {
        AgentSystemPresentationScope(
            project: scopedProject,
            conversation: conversation
        )
    }

    private var agentRunPresentation: AgentSystemScopePresentation {
        #if DEBUG
        if let fixture = AgentCanonicalStreamingPerformanceFixture
            .presentation(
                scope: agentPresentationScope,
                stream: runtime.liveStream,
                isWorking: runtime.isWorking
            ) {
            return fixture
        }
        #endif
        return agentSystemPresentation.presentation(
            for: agentPresentationScope
        )
    }

    private var agentOrchestrationPresentation: AgentOrchestrationPresentation? {
        agentSystemPresentation.orchestrationPresentation(
            for: agentPresentationScope
        )
    }

    private var agentWorkspace: SandboxWorkspace {
        SandboxWorkspace(
            name: scopedProject?.workspaceName ?? settings.activeWorkspaceName
        )
    }

    private var selectedWorkspaceID: WorkspaceID? {
        guard let identity = try? WorkspaceResourceIdentity(
            workspace: agentWorkspace
        ) else { return nil }
        return WorkspaceID(rawValue: identity.persistentID)
    }

    private var workspaceAgentPresentation: AgentSystemScopePresentation? {
        guard let selectedWorkspaceID else { return nil }
        return agentSystemPresentation.activePresentation(
            in: selectedWorkspaceID
        )
    }

    private var canonicalRunOwnsSelectedConversation: Bool {
        agentRunPresentation.activeGroup != nil ||
            agentRunPresentation.isAccepting ||
            agentRunPresentation.isSynchronizing
    }

    private var canonicalRunIsActive: Bool {
        agentRunPresentation.blocksCommand
    }

    private var canonicalRunIsWorking: Bool {
        agentRunPresentation.isWorking
    }

    private var canonicalPendingApproval: AgentActivityApproval? {
        agentRunPresentation.pendingApproval
    }

    /// Durable evidence follows the selected conversation's scope, not the
    /// project currently selected elsewhere in the app. Including the
    /// conversation ID makes a General chat and a project chat distinct even
    /// when a caller reuses this view instance during navigation.
    private var evidenceScopeIdentity: String {
        let projectID = scopedProject.map { $0.id.uuidString } ?? "general"
        return "\(conversation.id.uuidString)-\(projectID)"
    }

    /// Runtime artifacts are transient and only safe to render while this
    /// exact conversation owns the runtime. Completed work is read from the
    /// durable snapshot instead, so switching chats can never borrow the
    /// previous chat's in-memory artifact shelf.
    private var runtimeIsBoundToSelectedConversation: Bool {
        guard let activeConversationID = runtime.activeConversationID else { return false }
        return activeConversationID == conversation.id
    }

    private var runtimeArtifactsForSelectedConversation: [WorkspaceArtifact] {
        guard runtimeIsBoundToSelectedConversation else { return [] }
        return runtime.currentArtifacts
    }

    private var missionContract: MissionOSContract {
        cachedMissionContract ?? Self.placeholderMissionContract(for: project)
    }

    private var latestMessageID: UUID? {
        cachedMessages.last?.id
    }

    private var latestScrollTargetID: String? {
        transcriptRows.isEmpty ? nil : Self.chatLatestAnchorID
    }

    private var transcriptBottomPadding: CGFloat {
        activeLayoutContract.transcriptBreathingRoom
    }

    private var accessoryBottomPadding: CGFloat {
        activeLayoutContract.accessoryBottomPadding
    }

    private var composerHorizontalPadding: CGFloat { 12 }

    private var chatChromeTint: Color { AgentPalette.primaryAccent }

    private var chatChromeTintID: String {
        "\(AgentTheme.current.id)-chat-chrome"
    }

    private var shouldAutoScrollForKeyboard: Bool {
        !cachedMessages.isEmpty || canonicalRunIsWorking ||
            (ownsActiveRunState && runtime.isWorking)
    }

    private var activeLayoutContract: ChatLayoutContract {
        ChatLayoutContract(
            keyboardVisible: keyboard.isVisible,
            composerMode: composerMode,
            runAccessory: runAccessoryState
        )
    }

    private var chatMode: ChatMode {
        guard ownsActiveRunState else { return .idle }
        if canonicalRunOwnsSelectedConversation {
            if canonicalPendingApproval != nil { return .pendingApproval }
            if agentRunPresentation.failure != nil ||
                agentRunPresentation.activeGroup?.state == .failed ||
                agentRunPresentation.activeGroup?.state == .rejected ||
                agentRunPresentation.activeGroup?.state == .cancelled ||
                agentRunPresentation.activeGroup?.state == .interrupted {
                return .failed
            }
            if canonicalRunIsWorking { return .streaming }
            if composerFocused || !trimmedPrompt.isEmpty { return .composing }
            if agentRunPresentation.activeGroup?.state == .succeeded {
                return .completed
            }
            return .idle
        }
        if runtime.pendingTool != nil { return .pendingApproval }
        if runtime.lastError != nil { return .failed }
        if runtime.isWorking { return .streaming }
        if composerFocused || !trimmedPrompt.isEmpty { return .composing }
        if hasCompletedRunEvidence { return .completed }
        return .idle
    }

    private var composerMode: ChatComposerMode {
        if hasForeignActiveRun || hasForeignProjectMission ||
            canonicalRunIsActive ||
            (ownsActiveRunState && runtime.pendingTool != nil) {
            return .disabled
        }
        if draftUsesExpandedComposer { return .expanded }
        if composerFocused { return .focused }
        return .compact
    }

    private var draftUsesExpandedComposer: Bool {
        prompt.contains("\n") || prompt.count > 28
    }

    private var runAccessoryState: ChatRunAccessoryState {
        guard ownsActiveRunState else { return .hidden }
        if canonicalRunOwnsSelectedConversation {
            if canonicalPendingApproval != nil { return .approval }
            if agentRunPresentation.failure != nil ||
                agentRunPresentation.activeGroup?.state == .failed ||
                agentRunPresentation.activeGroup?.state == .rejected ||
                agentRunPresentation.activeGroup?.state == .cancelled ||
                agentRunPresentation.activeGroup?.state == .interrupted {
                return .failure
            }
            if canonicalRunIsWorking { return .progress }
            return .hidden
        }
        if runtime.pendingTool != nil { return .approval }
        if runtime.lastError != nil || runtime.wasInterrupted { return .failure }
        if runtime.isWorking || runtime.queuedPromptCount > 0 { return .progress }
        return .hidden
    }

    private var hasCompletedRunEvidence: Bool {
        agentRunPresentation.activeGroup?.state == .succeeded ||
            runtime.lastRunDuration != nil ||
            runtime.runState == .completed ||
            runtime.hasSuccessfulTraceEvent ||
            !runtimeArtifactsForSelectedConversation.isEmpty ||
            !cachedArtifacts.isEmpty ||
            cachedDurableRunSnapshot.hasCompletionEvidence
    }

    private var isNearChatBottom: Bool {
        scrollAttachment != .detached
    }

    private var showJumpToLatest: Bool {
        scrollAttachment == .detached && hasLatestJumpTarget
    }

    private var shouldTopAnchorEmptyTranscript: Bool {
        cachedMessages.isEmpty &&
            !hasForeignActiveRun &&
            !canonicalRunIsActive &&
            !(ownsActiveRunState && (runtime.isWorking || runtime.pendingTool != nil))
    }

    private var shouldShowLiveResponseIsland: Bool {
        ownsActiveRunState &&
            (agentRunPresentation.liveText != nil ||
                (canonicalRunIsWorking &&
                    agentRunPresentation.activeGroup != nil))
    }

    private var missionStripIsVisible: Bool {
        guard ForgeMissionStrip.isVisible(
            scopedProject: scopedProject,
            status: missionStatus,
            autoContinue: missionAutoContinue
        ) else { return false }

        // A selected chat's active response is controlled directly from the
        // composer. Preserve the mission strip for approvals and countdowns,
        // but do not repeat the same working state and Stop action at the top.
        if missionUsesChatRuntime,
           composerOwnsWorkingRun,
           missionStatus.tone == .working,
           !missionAutoContinue.isCountingDown {
            return false
        }
        return true
    }

    private var hasUserMessageInVisibleThread: Bool {
        visibleMessages.contains { $0.role == .user }
    }

    private var latestVisibleMessageSupportsQuickActions: Bool {
        let messages = visibleMessages
        guard let latest = messages.last else { return false }
        let recentMessagesArePlainText = messages.suffix(3).allSatisfy { message in
            message.toolCalls.isEmpty && message.artifact == nil
        }
        return latest.role == .assistant &&
            latest.toolCalls.isEmpty &&
            latest.artifact == nil &&
            recentMessagesArePlainText &&
            !latest.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var shouldShowFirstRunGuides: Bool {
        false
    }

    /// First run on the local brain: the empty chat IS the setup moment —
    /// reactor gauge, one download action — not a clipped chip pointing at
    /// Settings. Extracted so the transcript ViewBuilder stays type-checkable.
    @ViewBuilder
    private var chatEmptyStateContent: some View {
        if settings.provider == .local, needsLocalPowerUp {
            FirstRunPowerUp(localModels: runtime.localModels)
        } else {
            CleanChatEmptyState(
                readiness: firstMissionReadiness,
                openSettings: { openWorkspaceSurface(.settings) }
            ) { starterPrompt in
                prompt = starterPrompt
                composerFocused = true
            }
        }
    }

    /// The local brain still needs installing, verification, resuming, or
    /// repair. Integrity checking is a real gate: no deterministic shortcut
    /// may run before the selected GGUF digest is proven.
    private var needsLocalPowerUp: Bool {
        switch runtime.localModels.status {
        case .checking, .missing, .partial, .downloading, .failed, .incompatible:
            return true
        case .ready:
            return false
        }
    }

    private var missingCredentialSetup: Bool {
        settings.provider != .local &&
            !runtime.hasUsableProviderCredential(settings: settings)
    }

    private var unsupportedAgentRoute: Bool {
        !settings.provider.supportsAgentRuntime ||
            !settings.provider.modelOptions.contains(settings.modelID)
    }

    private var providerSetupBlocksComposer: Bool {
        unsupportedAgentRoute || missingCredentialSetup ||
            (settings.provider == .local && needsLocalPowerUp)
    }

    private var firstMissionReadiness: CleanChatEmptyState.Readiness {
        if unsupportedAgentRoute {
            return CleanChatEmptyState.Readiness(
                title: "Choose an agent-ready model",
                detail: "This saved legacy route cannot run the new agent system. Choose Zen, Local, ChatGPT, or OpenAI in Control.",
                symbol: "arrow.triangle.branch",
                tint: AgentPalette.warning,
                actionTitle: "Control",
                badgeTitle: "CHOOSE"
            )
        }

        if missingCredentialSetup {
            if settings.provider == .openAICodex {
                return CleanChatEmptyState.Readiness(
                    title: "Sign in with ChatGPT",
                    detail: "Connect your ChatGPT subscription in Control, then supported GPT agent runs can use its included allowance.",
                    symbol: "person.crop.circle.badge.checkmark",
                    tint: AgentPalette.indigo,
                    actionTitle: "Control",
                    badgeTitle: "SIGN IN"
                )
            }
            return CleanChatEmptyState.Readiness(
                title: "\(settings.provider.displayName) needs a key",
                detail: "Add the key once in Control, then these starter missions can run for real.",
                symbol: "key.slash.fill",
                tint: AgentPalette.rose,
                actionTitle: "Control",
                badgeTitle: "SETUP"
            )
        }

        if settings.provider == .local {
            return CleanChatEmptyState.Readiness(
                title: "Local model ready",
                detail: "\(runtime.localModels.selectedVariant.shortName) is ready for private on-device work.",
                symbol: "cpu.fill",
                tint: AgentPalette.green,
                actionTitle: nil,
                badgeTitle: "READY"
            )
        }

        return CleanChatEmptyState.Readiness(
            title: "\(settings.provider.displayName) key saved",
            detail: "The model route is recognized. Use Check key in Control whenever you want a live provider check.",
            symbol: settings.provider.symbol,
            tint: settings.provider.tint,
            actionTitle: nil,
            badgeTitle: "KEY SAVED"
        )
    }

    private var shouldShowProjectStatusBoard: Bool {
        false
    }

    private var hasLegacyRunState: Bool {
        #if DEBUG
        if hostedTextCanarySession.locksWorkspaceRouting { return true }
        #endif
        return runtime.isWorking ||
            runtime.pendingTool != nil ||
            runtime.lastError != nil ||
            runtime.queuedPromptCount > 0 ||
            runtime.wasInterrupted ||
            runtime.lastRunDuration != nil ||
            runtime.runState == .completed ||
            !runtime.currentArtifacts.isEmpty ||
            runtime.hasTraceEvents ||
            cachedDurableRunSnapshot.hasCompletionEvidence
    }

    private var hasRunState: Bool {
        canonicalRunOwnsSelectedConversation || hasLegacyRunState
    }

    private var ownsActiveRunState: Bool {
        if canonicalRunOwnsSelectedConversation { return true }
        if let workspaceAgentPresentation,
           workspaceAgentPresentation.blocksCommand {
            return workspaceAgentPresentation.scope == agentPresentationScope
        }
        #if DEBUG
        if hostedTextCanarySession.locksWorkspaceRouting {
            return canaryOwnsSelectedConversation
        }
        guard hasLegacyRunState else { return true }
        guard let activeConversationID = runtime.activeConversationID else {
            return true
        }
        return activeConversationID == conversation.id
        #else
        return true
        #endif
    }

    private var hasForeignActiveRun: Bool {
        if let workspaceAgentPresentation,
           workspaceAgentPresentation.blocksCommand,
           workspaceAgentPresentation.scope != agentPresentationScope {
            return true
        }
        #if DEBUG
        return hasLegacyRunState && !ownsActiveRunState
        #else
        return false
        #endif
    }

    private var hasForeignProjectMission: Bool {
        hasForeignActiveRun || (scopedProject != nil &&
            !missionUsesChatRuntime &&
            missionStatus.blocksCommand)
    }

    private var activeElsewhereTitle: String {
        if let active = activeElsewhereConversation,
           workspaceAgentPresentation?.blocksCommand == true {
            let title = active.title.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            return title.isEmpty ? "NovaForge" : title
        }
        #if DEBUG
        if hostedTextCanarySession.locksWorkspaceRouting,
           let active = activeElsewhereConversation {
            let title = active.title.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            return title.isEmpty ? "NovaForge" : title
        }
        #endif
        let title = runtime.activeConversationTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if title.isEmpty || title == LaunchConversationSelection.safeStartTitle {
            return "NovaForge"
        }
        return title
    }

    private var activeElsewhereConversation: Conversation? {
        if let conversationID = workspaceAgentPresentation?.scope
            .conversationID.rawValue,
           conversationID != conversation.id,
           let activeConversation = conversations.first(where: { $0.id == conversationID }) {
            return activeConversation
        }
        #if DEBUG
        if hostedTextCanarySession.locksWorkspaceRouting,
           let conversationID = hostedTextCanarySession.activeDraftIdentity?.conversationID,
           let activeConversation = conversations.first(where: { $0.id == conversationID }) {
            return activeConversation
        }
        #endif
        guard let activeConversationID = runtime.activeConversationID else { return nil }
        if let activeConversation = conversations.first(where: {
            $0.id == activeConversationID
        }) {
            return activeConversation
        }
        return runtime.activeRunConversation
    }

    private var protectedConversationID: UUID? {
        if let workspaceAgentPresentation,
           workspaceAgentPresentation.blocksCommand {
            return workspaceAgentPresentation.scope.conversationID.rawValue
        }
        #if DEBUG
        if hostedTextCanarySession.locksWorkspaceRouting {
            return hostedTextCanarySession.activeDraftIdentity?.conversationID
        }
        #endif
        guard runtime.isWorking || runtime.pendingTool != nil ||
                runtime.queuedPromptCount > 0 else { return nil }
        return runtime.activeConversationID ?? conversation.id
    }

    #if DEBUG
    private var canaryOwnsSelectedConversation: Bool {
        hostedTextCanarySession.locksWorkspaceRouting &&
            hostedTextCanarySession.activeDraftIdentity?.conversationID ==
                conversation.id
    }

    private var canaryIsActivelyWorking: Bool {
        guard canaryOwnsSelectedConversation else { return false }
        switch hostedTextCanarySession.phase {
        case .accepting, .running, .stopping:
            return true
        case .idle, .blockedRecovery:
            return false
        }
    }
    #endif

    private var conversationRefreshID: String {
        "\(evidenceScopeIdentity)-\(conversation.messageCount)-\(conversation.updatedAt.timeIntervalSince1970)"
    }

    private var missionContractRefreshID: String {
        guard let scopedProject else {
            return [
                evidenceScopeIdentity,
                "general",
                String(conversation.updatedAt.timeIntervalSince1970),
                String(conversation.messageCount)
            ].joined(separator: "-")
        }
        return [
            evidenceScopeIdentity,
            scopedProject.statusRawValue,
            String(scopedProject.updatedAt.timeIntervalSince1970),
            String(scopedProject.lastActivityAt.timeIntervalSince1970),
            String(conversation.updatedAt.timeIntervalSince1970),
            String(conversation.messageCount)
        ].joined(separator: "-")
    }

    private var durableRunRefreshID: String {
        // ProjectEventRecorder advances both timestamps whenever project-scoped
        // evidence changes. Use that canonical revision instead of faulting six
        // relationships and scanning every child timestamp during each Chat
        // body evaluation.
        let scopeSnapshot: String
        if let scopedProject {
            scopeSnapshot = [
                evidenceScopeIdentity,
                scopedProject.statusRawValue,
                String(scopedProject.updatedAt.timeIntervalSince1970),
                String(scopedProject.lastActivityAt.timeIntervalSince1970)
            ].joined(separator: "-")
        } else {
            scopeSnapshot = "\(evidenceScopeIdentity)-general"
        }
        let runtimeSnapshot: String
        if runtimeIsBoundToSelectedConversation {
            runtimeSnapshot = [
                String(runtimeArtifactsForSelectedConversation.count),
                String(runtime.hasTraceEvents),
                String(runtime.lastRunDuration ?? 0),
                String(describing: runtime.runState)
            ].joined(separator: "-")
        } else {
            runtimeSnapshot = "0-false-0-idle"
        }
        return [
            scopeSnapshot,
            runtimeSnapshot,
            String(conversation.updatedAt.timeIntervalSince1970),
            String(conversation.messageCount)
        ].joined(separator: "-")
    }

    private func headerTopPadding(for safeAreaTop: CGFloat) -> CGFloat {
        safeAreaTop > 1 ? 10 : 18
    }

    private func updateCachedMessages() {
        let signpostID = AgentPerformance.begin("Chat Message Cache")
        let generation = transient.messageCacheGeneration + 1
        transient.messageCacheGeneration = generation
        transient.messageCacheTask?.cancel()
        let previousCachedCount = cachedMessages.count

        let conversationID = conversation.id
        let scopeIdentity = evidenceScopeIdentity
        let fetchLimit = max(messageRenderWindowSize, messageRenderLimit)
        let relationshipSources = Self.recentMessageSources(from: conversation.messages, limit: fetchLimit)
        let sources: [ChatMessageSource]
        do {
            var descriptor = FetchDescriptor<ChatMessage>(
                predicate: #Predicate<ChatMessage> { message in
                    message.conversation?.id == conversationID
                },
                sortBy: [SortDescriptor(\ChatMessage.createdAt, order: .reverse)]
            )
            descriptor.fetchLimit = fetchLimit
            let fetched = try modelContext.fetch(descriptor)
            let ordered = fetched.reversed()
            sources = Self.mergedRecentMessageSources(
                fetched: ordered.map(ChatMessageSource.init),
                relationship: relationshipSources,
                limit: fetchLimit
            )
        } catch {
            sources = relationshipSources
        }
        let runtimeArtifacts = runtimeArtifactsForSelectedConversation

        // In expanded-history mode, keep older assistant bubbles readable but avoid
        // re-parsing every historical markdown/code block on the render path.
        // The newest window still gets full markdown/code parsing.
        let parseAllMessages = fetchLimit <= messageRenderWindowSize
        let parseWindowSize = messageRenderWindowSize

        transient.messageCacheTask = Task {
            defer {
                AgentPerformance.end("Chat Message Cache", id: signpostID)
            }
            let snapshots = await Self.buildMessageSnapshots(
                from: sources,
                parseAllMessages: parseAllMessages,
                parseWindowSize: parseWindowSize
            )
            guard !Task.isCancelled,
                  transient.messageCacheGeneration == generation,
                  conversation.id == conversationID,
                  evidenceScopeIdentity == scopeIdentity else { return }
            if snapshots.count > previousCachedCount {
                AgentPerformance.event("Chat Message Append")
            }
            cachedMessages = snapshots
            cachedSourceMessageCount = sources.count
            updateCachedArtifacts(from: snapshots, runtimeArtifacts: runtimeArtifacts)
        }
    }

    private nonisolated static func buildMessageSnapshots(
        from sources: [ChatMessageSource],
        parseAllMessages: Bool,
        parseWindowSize: Int
    ) async -> [ChatMessageSnapshot] {
        // A nonisolated async helper runs on the cooperative executor while
        // remaining a structured child of messageCacheTask. Cancellation can
        // no longer leave an unowned detached markdown parse running behind a
        // newer conversation refresh.
        await Task.yield()
        guard !Task.isCancelled else { return [] }
        let snapshots = ChatMessageSnapshot.make(
            from: sources,
            parseAllMessages: parseAllMessages,
            parseWindowSize: parseWindowSize
        )
        return Task.isCancelled ? [] : snapshots
    }

    private func refreshMissionContract() {
        let signpostID = AgentPerformance.begin("Chat Mission Contract Build")
        if let scopedProject {
            let summary = ProjectMissionSummarizer.summarize(project: scopedProject, context: modelContext)
            cachedMissionContract = summary.missionContract
            cachedWorkflowSpine = summary.workflowSpine
        } else {
            cachedMissionContract = nil
            cachedWorkflowSpine = nil
        }
        AgentPerformance.end("Chat Mission Contract Build", id: signpostID)
    }

    private func refreshDurableRunSnapshot() {
        cachedDurableRunSnapshot = ChatDurableRunSnapshot.make(
            project: scopedProject,
            conversation: conversation,
            context: modelContext
        )
        updateCachedArtifacts(
            from: cachedMessages,
            runtimeArtifacts: runtimeArtifactsForSelectedConversation
        )
    }

    private func refreshCanonicalActivity() async {
        let scopeIdentity = evidenceScopeIdentity
        let scope = AgentActivityProjectionScope(
            projectID: scopedProject.map { ProjectID(rawValue: $0.id) },
            conversationID: ConversationID(rawValue: conversation.id)
        )
        do {
            let groups = try await AgentCanonicalActivityRepository(
                container: modelContext.container
            ).groups(in: scope)
            guard !Task.isCancelled,
                  evidenceScopeIdentity == scopeIdentity else { return }
            cachedActivityGroups = groups
            canonicalActivityLoadFailed = false
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled,
                  evidenceScopeIdentity == scopeIdentity else { return }
            // Canonical corruption or an intentionally bounded oversized
            // scope must never fall back to reconstructing provider tool JSON.
            cachedActivityGroups = []
            canonicalActivityLoadFailed = true
        }
    }

    private func handleActivityCommand(_ command: AgentActivityCommand) {
        switch command {
        case .cancel, .resolveApproval:
            Task { @MainActor in
                do {
                    _ = try await agentSystemPresentation.route(command)
                } catch {
                    runtime.presentToast(
                        AgentSystemPresentationFailure.commandUnavailable
                            .userMessage,
                        tone: .error
                    )
                }
            }
        case let .retry(retry):
            Task { @MainActor in
                do {
                    let routed = try await agentSystemPresentation.route(
                        command
                    )
                    guard routed == .navigation(.retry(retry)) else {
                        throw AgentSystemActivityCommandRouterError
                            .staleActivityCommand
                    }
                    let disposition = await agentSystemPresentation.retry(
                        retry,
                        conversation: conversation,
                        project: scopedProject,
                        workspace: agentWorkspace,
                        settings: settings
                    )
                    switch disposition {
                    case .accepted:
                        forceScrollToBottom = true
                        scrollAttachment = .restoring
                        UIImpactFeedbackGenerator(style: .medium)
                            .impactOccurred()
                        requestJumpToLatest(
                            animated: true,
                            delay: .milliseconds(60)
                        )
                    case .busy:
                        runtime.presentToast(
                            AgentSystemPresentationFailure.workspaceBusy
                                .userMessage,
                            tone: .info
                        )
                    case .rejected(let failure):
                        runtime.presentToast(
                            failure.userMessage,
                            tone: .error
                        )
                    }
                } catch {
                    runtime.presentToast(
                        AgentSystemPresentationFailure.commandUnavailable
                            .userMessage,
                        tone: .error
                    )
                }
            }
        case .openReceipt:
            openWorkspaceSurface(.history)
        case .openArtifact:
            openWorkspaceSurface(.workspace)
        }
    }

    private func reviewActivityApproval(_ approval: AgentActivityApproval) {
        let pending = AgentPolicyMutationRuntime.shared.approvalPromptCenter.pendingItem
        guard pending?.requestID == approval.id,
              pending?.runID == approval.run.runID,
              pending?.callID == approval.callID else {
            openWorkspaceSurface(.history)
            return
        }
        // The exact request is already being presented by AppRoot's sheet.
        // Keeping this method identity-only prevents the compact row from
        // manufacturing or directly submitting approval authority.
    }

    private static func placeholderMissionContract(for project: Project) -> MissionOSContract {
        let mission = project.mission.trimmingCharacters(in: .whitespacesAndNewlines)
        let missionText = mission.isEmpty ? "Build and verify useful work in NovaForge." : mission
        let nextStep = project.nextStep.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Send the next project request." : project.nextStep
        let statusKind: ProjectMissionStatusKind = {
            switch project.status {
            case .blocked:
                return .blocked
            case .completed:
                return .done
            case .needsReview:
                return .waiting
            case .active, .running:
                return .active
            }
        }()
        return MissionOSContractBuilder.make(
            project: project,
            missionText: missionText,
            statusKind: statusKind,
            conversations: [],
            toolRuns: [],
            terminalCommands: [],
            artifacts: [],
            fileChanges: [],
            events: [],
            failures: statusKind == .blocked ? 1 : 0,
            pendingApprovals: statusKind == .waiting ? 1 : 0,
            nextStep: nextStep,
            proofItems: []
        )
    }

    private nonisolated static func recentMessageSources(from messages: [ChatMessage], limit: Int) -> [ChatMessageSource] {
        guard limit > 0, !messages.isEmpty else { return [] }
        guard messages.count > limit * 2 else {
            return messages
                .sorted(by: Self.messageAscending)
                .suffix(limit)
                .map(ChatMessageSource.init)
        }

        var newest: [ChatMessage] = []
        newest.reserveCapacity(limit + 1)
        for message in messages {
            newest.append(message)
            guard newest.count > limit else { continue }
            if let oldestIndex = newest.indices.min(by: { lhs, rhs in
                Self.messageAscending(newest[lhs], newest[rhs])
            }) {
                newest.remove(at: oldestIndex)
            }
        }
        return newest.sorted(by: Self.messageAscending).map(ChatMessageSource.init)
    }

    private nonisolated static func mergedRecentMessageSources(
        fetched: [ChatMessageSource],
        relationship: [ChatMessageSource],
        limit: Int
    ) -> [ChatMessageSource] {
        guard limit > 0 else { return [] }
        guard !fetched.isEmpty || !relationship.isEmpty else { return [] }

        var sourcesByID: [UUID: ChatMessageSource] = [:]
        sourcesByID.reserveCapacity(fetched.count + relationship.count)
        for source in fetched {
            sourcesByID[source.id] = source
        }
        // Prefer relationship values so newly inserted, not-yet-flushed messages
        // cannot disappear if a SwiftData fetch lags behind the model graph.
        for source in relationship {
            sourcesByID[source.id] = source
        }

        return Array(
            sourcesByID.values
                .sorted(by: Self.messageSourceAscending)
                .suffix(limit)
        )
    }

    private nonisolated static func messageAscending(_ lhs: ChatMessage, _ rhs: ChatMessage) -> Bool {
        if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    private nonisolated static func messageSourceAscending(_ lhs: ChatMessageSource, _ rhs: ChatMessageSource) -> Bool {
        if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    private func updateCachedArtifacts(
        from messages: [ChatMessageSnapshot],
        runtimeArtifacts: [WorkspaceArtifact] = []
    ) {
        var seen = Set<String>()
        var artifacts = runtimeArtifacts
        seen.formUnion(artifacts.map(\.path))

        for artifact in cachedDurableRunSnapshot.artifacts where seen.insert(artifact.path).inserted {
            artifacts.append(artifact)
        }

        for message in messages.reversed() where message.role == .tool {
            guard let artifact = message.artifact else { continue }
            if seen.insert(artifact.path).inserted {
                artifacts.append(artifact)
            }
            if artifacts.count >= 4 {
                break
            }
        }
        self.cachedArtifacts = Array(artifacts.prefix(4))
    }

    private func clearScopedEvidenceCaches() {
        cachedArtifacts = []
        cachedActivityGroups = []
        canonicalActivityLoadFailed = false
        cachedDurableRunSnapshot = .empty
        cachedMissionContract = nil
        cachedWorkflowSpine = nil
    }

    var body: some View {
        #if DEBUG
        if AgentPerformance.shouldProfileViewChanges {
            let _ = Self._printChanges()
        }
        #endif
        let _ = AgentPerformance.bodyEvaluation("Chat Body")
        GeometryReader { rootProxy in
            chatLayout(topSafeArea: rootProxy.safeAreaInsets.top)
        }
    }

    private func chatLayout(topSafeArea: CGFloat) -> some View {
        let _ = AgentPerformance.bodyEvaluation("Chat Layout")
        let showsMissionStrip = missionStripIsVisible
        return ZStack {
            ChatTranscriptBackdrop()

            VStack(spacing: 0) {
                GlassGroup(spacing: 9) {
                    VStack(spacing: 9) {
                        ForgeHeader(
                            projects: projects,
                            scopedProject: scopedProject,
                            conversation: conversation,
                            newChat: newChat,
                            changeScope: { selectedProject in
                                setConversationProjectScope(conversation, selectedProject)
                            },
                            createProject: createProject,
                            openMissionDossier: openMissionDossier,
                            openChatDrawer: {
                                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                withAnimation(shouldAnimateDecorative ? .smooth(duration: 0.22) : nil) {
                                    showingChatDrawer = true
                                }
                            },
                            glassNamespace: glassNamespace
                        )

                        if showsMissionStrip {
                            ForgeMissionStrip(
                                project: project,
                                scopedProject: scopedProject,
                                status: missionStatus,
                                autoContinue: missionAutoContinue,
                                glassNamespace: glassNamespace,
                                approve: approveMissionTool,
                                reject: rejectMissionTool,
                                stop: stopMissionRun,
                                pauseAutoContinue: pauseMissionAutoContinue,
                                openDossier: openMissionDossier
                            )
                            .transition(.move(edge: .top).combined(with: .opacity))
                        }
                    }
                }
                .padding(.horizontal)
                .padding(.top, headerTopPadding(for: topSafeArea))
                .padding(.bottom, 12)
                .background {
                    ChatHeaderBackground()
                }
                .zIndex(4)

                ScrollViewReader { proxy in
                    ZStack(alignment: .bottom) {
                        ScrollView(showsIndicators: false) {
                            VStack(spacing: 0) {
                                LazyVStack(spacing: 14) {
                                    if shouldShowFirstRunGuides {
                                        EmptyView()
                                    }

                                    if shouldShowProjectStatusBoard {
                                        EmptyView()
                                    }

                                    if cachedMessages.isEmpty && !hasForeignActiveRun &&
                                        !canonicalRunIsActive &&
                                        !(ownsActiveRunState &&
                                            (runtime.isWorking || runtime.pendingTool != nil)) {
                                        chatEmptyStateContent
                                            .padding(.horizontal)
                                            .transition(.opacity)
                                    }

                                    if hasForeignActiveRun {
                                        ActiveResponseElsewhereCard(
                                            title: activeElsewhereTitle,
                                            open: openActiveConversation
                                        )
                                        .padding(.horizontal)
                                        .transition(.opacity)
                                    }

                                    if hiddenMessageCount > 0 || messageRenderLimit > messageRenderWindowSize {
                                        ThreadWindowBanner(
                                            hiddenCount: hiddenMessageCount,
                                            showingFullThread: hiddenMessageCount == 0 && messageRenderLimit > messageRenderWindowSize,
                                            toggle: toggleThreadWindow
                                        )
                                        .padding(.horizontal)
                                        .transition(.opacity)
                                    }

                                    ForEach(transcriptRows) { row in
                                        Group {
                                            switch row {
                                            case .message(let message):
                                                messageBubble(for: message)
                                            case .activity(let group):
                                                AgentActivityGroupView(
                                                    group: group,
                                                    onCommand: handleActivityCommand,
                                                    onReviewApproval: reviewActivityApproval
                                                )
                                                .padding(.horizontal, 18)
                                            case .activityUnavailable:
                                                CanonicalActivityUnavailableView {
                                                    openWorkspaceSurface(.history)
                                                }
                                                .padding(.horizontal, 18)
                                            case .live:
                                                ChatLiveResponseIsland(
                                                    stream: agentLiveStream,
                                                    isWorking: canonicalRunIsWorking,
                                                    isVisibleForFrameProfiling: isVisibleForFrameProfiling
                                                )
                                            }
                                        }
                                        .id(row.id)
                                    }
                                }
                                .padding(.top, 20)

                                Color.clear
                                    .frame(height: latestResponseClearance)
                                    .accessibilityHidden(true)

                                Color.clear
                                    .frame(height: transcriptBottomPadding)
                                    .accessibilityHidden(true)
                                    .id(Self.chatLatestAnchorID)

                                Color.clear
                                    .frame(height: 1)
                                    .accessibilityHidden(true)
                                    .id(Self.chatBottomID)
                            }
                        }
                        .coordinateSpace(name: Self.chatScrollSpace)
                        .accessibilityIdentifier("chatTranscriptScroll")
                        .scrollContentBackground(.hidden)
                        .scrollIndicators(.hidden)
                        .scrollDismissesKeyboard(.interactively)
                        .defaultScrollAnchor(shouldTopAnchorEmptyTranscript ? .top : .bottom, for: .initialOffset)
                        .contentShape(Rectangle())
                        .simultaneousGesture(
                            DragGesture(minimumDistance: 14, coordinateSpace: .named(Self.chatScrollSpace))
                                .onChanged { value in
                                    handleUserScrollGesture(value)
                                }
                        )
                        .onTapGesture {
                            composerFocused = false
                        }
                        .onScrollGeometryChange(for: Int.self) { geometry in
                            let distanceToContentBottom = max(0, geometry.contentSize.height - geometry.visibleRect.maxY)
                            let distance = max(0, distanceToContentBottom - transcriptBottomPadding)
                            let bucketSize: CGFloat = AgentPerformance.isPerformanceMode ? 24 : 8
                            return Int((distance / bucketSize).rounded())
                        } action: { _, distanceBucket in
                            let bucketSize: CGFloat = AgentPerformance.isPerformanceMode ? 24 : 8
                            scheduleBottomDistanceUpdate(CGFloat(distanceBucket) * bucketSize)
                        }
                        .onScrollPhaseChange { _, newPhase, context in
                            handleScrollPhaseChange(newPhase, context: context)
                        }
                        .onAppear {
                            let shouldInitialScroll = canonicalRunIsWorking ||
                                (ownsActiveRunState && runtime.isWorking) ||
                                forceScrollToBottom || !visibleMessages.isEmpty
                            guard shouldInitialScroll else { return }
                            forceScrollToBottom = true
                            scrollAttachment = .restoring
                            requestJumpToLatest(animated: false, delay: .milliseconds(180))
                        }
                        .onChange(of: latestMessageID) { oldValue, newValue in
                            handleLatestMessageChange(oldValue: oldValue, newValue: newValue)
                        }
                        .onChange(of: runtime.isWorking) {
                            if ownsActiveRunState && runtime.isWorking {
                                scrollAttachment = .restoring
                                forceScrollToBottom = true
                                requestJumpToLatest(animated: true, delay: .milliseconds(80))
                            } else {
                                forceScrollToBottom = false
                                settleLiveStreamHandoff(animated: false)
                            }
                        }
                        .onChange(of: runtime.runState) { _, newState in
                            handleRunStateChange(newState)
                        }
                        .onReceive(runtime.liveStream.$layoutRevision) { _ in
                            #if DEBUG
                            if AgentCanonicalStreamingPerformanceFixture
                                .isEnabled {
                                synchronizeAgentLiveStream()
                            }
                            #endif
                            keepLiveStreamReadableDuringGrowth()
                        }
                        .onReceive(agentLiveStream.$layoutRevision) { _ in
                            // Canonical AgentSystem text grows in its own
                            // buffer. Follow its actual layout revisions so a
                            // new line cannot advance beneath the glass dock.
                            keepLiveStreamReadableDuringGrowth()
                        }
                        .onChange(of: composerFocused) {
                            guard composerFocused else { return }
                            guard shouldAutoScrollForKeyboard else { return }
                            guard shouldKeepTranscriptPinned else { return }
                            forceScrollToBottom = true
                            scrollAttachment = .restoring
                            requestJumpToLatest(animated: true, delay: .milliseconds(120))
                        }
                        Color.clear
                            .frame(width: 0, height: 0)
                            .onChange(of: jumpToLatestRequest) {
                                guard jumpToLatestRequest > 0 else { return }
                                scrollToLatest(proxy, animated: jumpToLatestAnimated)
                            }

                    }
                }
            }
            .onChange(of: runtime.currentArtifacts) {
                updateCachedArtifacts(
                    from: cachedMessages,
                    runtimeArtifacts: runtimeArtifactsForSelectedConversation
                )
            }
            .task(id: conversationRefreshID) {
                updateCachedMessages()
            }
            .task(id: missionContractRefreshID) {
                refreshMissionContract()
            }
            .task(id: durableRunRefreshID) {
                refreshDurableRunSnapshot()
            }
            .task(id: "canonical-activity-\(durableRunRefreshID)") {
                await refreshCanonicalActivity()
            }
            .onChange(
                of: agentSystemPresentation.revision,
                initial: true
            ) {
                synchronizeAgentLiveStream()
            }
            .onChange(
                of: agentRunPresentation.activeGroup,
                initial: true
            ) {
                updateCachedMessages()
                refreshDurableRunSnapshot()
                Task { @MainActor in
                    await refreshCanonicalActivity()
                }
            }
            .onAppear {
                #if DEBUG || targetEnvironment(simulator)
                if ProcessInfo.processInfo.arguments.contains("--keyboard-multiline-draft-demo") {
                    prompt = "First line of a preserved draft\nSecond line stays in the composer"
                    forceScrollToBottom = true
                    composerFocused = true
                    if shouldAutoScrollForKeyboard {
                        requestJumpToLatest(animated: true, delay: .milliseconds(160))
                    }
                } else if ProcessInfo.processInfo.arguments.contains("--keyboard-long-composer-demo") {
                    prompt = "Build me a smooth native iPhone app with a glassy chat composer that expands over multiple lines without jumping above the keyboard"
                    forceScrollToBottom = true
                    composerFocused = true
                    if shouldAutoScrollForKeyboard {
                        requestJumpToLatest(animated: true, delay: .milliseconds(160))
                    }
                } else if ProcessInfo.processInfo.arguments.contains("--keyboard-layout-demo") {
                    prompt = "Testing keyboard layout"
                    forceScrollToBottom = true
                    composerFocused = true
                    if shouldAutoScrollForKeyboard {
                        requestJumpToLatest(animated: true, delay: .milliseconds(160))
                    }
                }
                if ProcessInfo.processInfo.arguments.contains("--keyboard-focus-demo") {
                    composerFocused = true
                }
                if ProcessInfo.processInfo.arguments.contains("--open-chat-drawer-demo") {
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(700))
                        withAnimation(.smooth(duration: 0.22)) {
                            showingChatDrawer = true
                        }
                    }
                }
                #endif
                applyProjectResumeDraftIfNeeded(focusComposer: projectResumeDraftRevision > 0)
                restorePersistedDraftIfAvailable()
            }
            .onReceive(NotificationCenter.default.publisher(for: NovaForgeIntentSignal.askPrompt)) { note in
                guard let text = note.userInfo?[NovaForgeIntentSignal.promptKey] as? String,
                      !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                prompt = text
                composerFocused = true
                if shouldAutoScrollForKeyboard {
                    requestJumpToLatest(animated: true, delay: .milliseconds(200))
                }
            }
            .onDisappear {
                flushDraftPersistence(prompt, for: conversation.id)
                transient.messageCacheGeneration += 1
                transient.messageCacheTask?.cancel()
                transient.messageCacheTask = nil
                transient.cancelLayoutTasks()
            }

        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            chatBottomAccessory
                .padding(.horizontal, 10)
                .padding(.top, 4)
                .padding(.bottom, accessoryBottomPadding)
                .background { ChatDockBackground() }
                .zIndex(5)
        }
        .sheet(isPresented: $showingRunDetails) {
            runDetailsSheet
        }
        .overlay(alignment: .leading) {
            if showingChatDrawer {
                ChatDrawerOverlay(
                    project: project,
                    conversations: projectConversations,
                    selectedConversationID: conversation.id,
                    protectedConversationID: protectedConversationID,
                    settings: settings,
                    selectConversation: { selected in
                        selectConversation(selected)
                    },
                    deleteConversationFromHistory: deleteConversationFromHistory,
                    newChat: {
                        newChat()
                    },
                    close: {
                        withAnimation(shouldAnimateDecorative ? .smooth(duration: 0.22) : nil) {
                            showingChatDrawer = false
                        }
                    }
                )
                .ignoresSafeArea(.container, edges: [.top, .bottom])
                .transition(.asymmetric(insertion: .opacity, removal: .opacity))
                .zIndex(10)
            }
        }
        .toolbar((keyboard.isVisible || showingChatDrawer) ? .hidden : .visible, for: .tabBar)
        .onChange(of: projectResumeDraftRevision) {
            applyProjectResumeDraftIfNeeded(focusComposer: true)
        }
        #if DEBUG
        .onChange(of: hostedTextCanarySession.revision) {
            handleHostedTextCanaryRevision()
        }
        #endif
        .onChange(of: activeLayoutContract) { oldValue, newValue in
            handleLayoutContractChange(oldValue: oldValue, newValue: newValue)
        }
        .onChange(of: chatMode) {
            AgentPerformance.event("Chat Mode Update")
        }
        .onChange(of: evidenceScopeIdentity) {
            // Scope can change without changing the conversation (for example,
            // moving a chat from a project back to General). Never leave the
            // previous scope's summary or proof shelf on screen while the new
            // scoped tasks rebuild them.
            clearScopedEvidenceCaches()
        }
        .onChange(of: conversation.id) { oldValue, _ in
            flushDraftPersistence(prompt, for: oldValue)
            transient.messageCacheGeneration += 1
            transient.messageCacheTask?.cancel()
            cachedMessages = []
            cachedSourceMessageCount = 0
            clearScopedEvidenceCaches()
            prompt = ""
            selectedArtifact = nil
            composerFocused = false
            showingChatDrawer = false
            showingRunDetails = false
            messageRenderLimit = messageRenderWindowSize
            transient.lastReportedBottomDistance = .infinity
            transient.accessoryResizeFollowUpTask?.cancel()
            transient.scrollRequestTask?.cancel()
            transient.manualRepinTask?.cancel()
            keyboard.reset()
            scrollAttachment = .pinned
            agentLiveStream.reset()
            agentLiveRunID = nil
            agentLiveAttemptID = nil
            agentLiveIngestedText = ""
            #if DEBUG
            hostedTextCanaryDraftToken = UUID()
            #endif
            forceScrollToBottom = conversation.messageCount > 0 ||
                composerOwnsWorkingRun
            restorePersistedDraftIfAvailable()
            synchronizeAgentLiveStream()
        }
        .onChange(of: prompt) {
            handlePromptChanged()
            scheduleDraftPersistence(prompt, for: conversation.id)
        }
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase != .active else { return }
            flushDraftPersistence(prompt, for: conversation.id)
        }
        .onChange(of: cachedSourceMessageCount) {
            if cachedSourceMessageCount <= messageRenderWindowSize {
                messageRenderLimit = messageRenderWindowSize
            }
            if hasLatestJumpTarget, shouldKeepTranscriptPinned {
                requestJumpToLatest()
            }
        }
        .fullScreenCover(item: $selectedArtifact) { artifact in
            ArtifactPreviewSheet(
                artifact: artifact,
                workspace: runtime.workspace,
                openLandscapeFullScreen: openArtifactLandscapeFullScreen,
                iterationPrompt: cachedWorkflowSpine?.iterationPrompt
            )
        }
        .alert(
            "Chat Save Error",
            isPresented: Binding(
                get: { chatSaveError != nil },
                set: { if !$0 { chatSaveError = nil } }
            )
        ) {
            Button("OK", role: .cancel) { chatSaveError = nil }
        } message: {
            Text(chatSaveError ?? "NovaForge could not save that chat change.")
        }
    }

    private func messageBubble(for message: ChatMessageSnapshot) -> some View {
        MessageBubble(
            message: message,
            workspace: runtime.workspace,
            tint: chatChromeTint,
            tintID: chatChromeTintID,
            actionScopeID: evidenceScopeIdentity,
            openArtifact: previewArtifact
        )
        .equatable()
        .id(message.id)
        .onAppear {
            acknowledgeLiveHandoffIfNeeded(for: message)
        }
    }

    private func acknowledgeLiveHandoffIfNeeded(for message: ChatMessageSnapshot) {
        if message.role == .assistant,
           let runID = message.runID,
           agentLiveRunID?.rawValue == runID {
            let completedRunID = agentLiveRunID
            agentLiveStream.reset()
            agentLiveRunID = nil
            agentLiveAttemptID = nil
            agentLiveIngestedText = ""
            if let completedRunID {
                Task { @MainActor in
                    await agentSystemPresentation.acknowledgeLiveHandoff(
                        runID: completedRunID
                    )
                }
            }
            if shouldKeepTranscriptPinned {
                scrollAttachment = .restoring
                requestJumpToLatest(animated: false)
            }
            return
        }
        guard message.role == .assistant,
              runtime.liveStream.handoffMessageID == message.id else { return }

        runtime.liveStream.clearHandoffIfRendered(messageID: message.id)
        guard shouldKeepTranscriptPinned else { return }

        // onAppear is the render acknowledgement. Queue one scroll request for
        // the next main-actor turn so it observes the durable row's final size.
        scrollAttachment = .restoring
        requestJumpToLatest(animated: false)
    }

    private func synchronizeAgentLiveStream() {
        let presentation = agentRunPresentation
        guard let runID = presentation.liveText?.runID ??
                presentation.activeGroup?.identity.runID
        else {
            if agentLiveRunID != nil {
                agentLiveStream.reset()
                agentLiveRunID = nil
                agentLiveAttemptID = nil
                agentLiveIngestedText = ""
            }
            return
        }

        if agentLiveRunID != runID {
            agentLiveStream.reset()
            agentLiveRunID = runID
            agentLiveAttemptID = nil
            agentLiveIngestedText = ""
        }
        guard let live = presentation.liveText else { return }

        if agentLiveAttemptID != live.attemptID ||
            !live.text.hasPrefix(agentLiveIngestedText) {
            agentLiveStream.reset()
            agentLiveAttemptID = live.attemptID
            agentLiveIngestedText = ""
        }
        guard live.text.count > agentLiveIngestedText.count else { return }
        let suffix = live.text.dropFirst(agentLiveIngestedText.count)
        agentLiveStream.append(String(suffix))
        agentLiveIngestedText = live.text
        keepLiveStreamReadableDuringGrowth()
    }

    private func previewArtifact(_ artifact: WorkspaceArtifact) {
        AgentPerformance.event("Artifact Preview Open")
        ProjectEventRecorder.noteArtifactPreview(
            artifact,
            project: scopedProject,
            context: modelContext
        )
        do {
            try modelContext.save()
        } catch {
            modelContext.rollback()
            chatSaveError = "NovaForge opened the artifact, but could not save the preview event. \(error.localizedDescription)"
        }
        selectedArtifact = artifact
    }

    private func applyProjectResumeDraftIfNeeded(focusComposer: Bool) {
        let draft = projectResumeDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard projectResumeDraftRevision > 0, !draft.isEmpty else { return }
        guard prompt != projectResumeDraft else { return }
        prompt = projectResumeDraft
        forceScrollToBottom = conversation.messageCount > 0 || (ownsActiveRunState && runtime.isWorking)
        if focusComposer {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                composerFocused = true
            }
        }
    }

    private func restorePersistedDraftIfAvailable() {
        guard prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard projectResumeDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard let draft = persistedDrafts()[conversation.id.uuidString],
              !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        prompt = draft
    }

    private func persistDraft(_ draft: String, for conversationID: UUID) {
        var drafts = persistedDrafts()
        let key = conversationID.uuidString
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            drafts.removeValue(forKey: key)
        } else {
            drafts[key] = draft
        }
        if drafts.count > 12 {
            let protectedKeys = Set([conversation.id.uuidString, key])
            let removable = drafts.keys
                .filter { !protectedKeys.contains($0) }
                .sorted()
            for staleKey in removable.prefix(max(0, drafts.count - 12)) {
                drafts.removeValue(forKey: staleKey)
            }
        }
        guard let data = try? JSONEncoder().encode(drafts),
              let json = String(data: data, encoding: .utf8) else { return }
        persistedDraftsJSON = json
    }

    private func scheduleDraftPersistence(_ draft: String, for conversationID: UUID) {
        transient.draftPersistenceTask?.cancel()
        transient.draftPersistenceTask = Task { @MainActor in
            do {
                try await Task.sleep(for: .milliseconds(450))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            persistDraft(draft, for: conversationID)
            transient.draftPersistenceTask = nil
        }
    }

    private func flushDraftPersistence(_ draft: String, for conversationID: UUID) {
        transient.draftPersistenceTask?.cancel()
        transient.draftPersistenceTask = nil
        persistDraft(draft, for: conversationID)
    }

    private func persistedDrafts() -> [String: String] {
        guard let data = persistedDraftsJSON.data(using: .utf8),
              let drafts = try? JSONDecoder().decode([String: String].self, from: data) else {
            return [:]
        }
        return drafts
    }

    private var chatBottomAccessory: some View {
        let _ = AgentPerformance.bodyEvaluation("Chat Bottom Accessory Body")
        return GlassGroup(spacing: 10) {
            VStack(spacing: 6) {
                if hasForeignActiveRun {
                    ActiveResponseElsewhereDock(title: activeElsewhereTitle, open: openActiveConversation)
                } else if shouldShowStandaloneContextBar {
                    ChatContextBar(
                        runtime: runtime,
                        settings: settings,
                        artifacts: cachedArtifacts,
                        durableSnapshot: cachedDurableRunSnapshot,
                        workflowSpine: cachedWorkflowSpine,
                        openArtifact: previewArtifact,
                        retry: {
                            runtime.retryLastPrompt(conversation: conversation, settings: settings, context: modelContext, project: scopedProject)
                        },
                        continueRun: {
                            runtime.continueAfterInterruption(conversation: conversation, settings: settings, context: modelContext, project: scopedProject)
                        },
                        stop: stopActiveRun,
                        openWorkspaceSurface: openWorkspaceSurface,
                        clear: { runtime.clearCurrentRunState(keepLastFailure: false) },
                        compact: false,
                        glassNamespace: glassNamespace,
                        expanded: runDetailsDisclosureBinding
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                composer
            }
        }
        .padding(.horizontal, composerHorizontalPadding)
        .padding(.vertical, 6)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chatBottomAccessory")
    }

    private var composerOwnsWorkingRun: Bool {
        if canonicalRunIsWorking { return true }
        #if DEBUG
        if canaryIsActivelyWorking { return true }
        #endif
        return ownsActiveRunState && runtime.isWorking
    }

    private var shouldShowStandaloneContextBar: Bool {
        shouldShowContextBar && !composerOwnsWorkingRun
    }

    private var runDetailsDisclosureBinding: Binding<Bool> {
        Binding(
            get: { false },
            set: { isPresented in
                if isPresented {
                    showingRunDetails = true
                }
            }
        )
    }

    private var runDetailsSheet: some View {
        NavigationStack {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 14) {
                    if let orchestration = agentOrchestrationPresentation {
                        AgentOrchestrationStatusCard(
                            presentation: orchestration
                        )
                    }
                    AgentProgressDrawer(
                        runtime: runtime,
                        tint: chatChromeTint,
                        artifacts: cachedArtifacts,
                        durableSnapshot: cachedDurableRunSnapshot,
                        workflowSpine: cachedWorkflowSpine,
                        openArtifact: previewArtifact,
                        retry: {
                            showingRunDetails = false
                            runtime.retryLastPrompt(
                                conversation: conversation,
                                settings: settings,
                                context: modelContext,
                                project: scopedProject
                            )
                        },
                        continueRun: {
                            showingRunDetails = false
                            runtime.continueAfterInterruption(
                                conversation: conversation,
                                settings: settings,
                                context: modelContext,
                                project: scopedProject
                            )
                        },
                        stop: {
                            stopActiveRun()
                        },
                        openWorkspaceSurface: { tab in
                            showingRunDetails = false
                            openWorkspaceSurface(tab)
                        },
                        clear: {
                            runtime.clearCurrentRunState(keepLastFailure: false)
                            showingRunDetails = false
                        }
                    )
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .background(ChatTranscriptBackdrop())
            .navigationTitle("Run details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        showingRunDetails = false
                    }
                    .frame(
                        minWidth: AgentDesign.minimumTouchTarget,
                        minHeight: AgentDesign.minimumTouchTarget
                    )
                    .contentShape(Rectangle())
                    .accessibilityIdentifier("runControlCloseButton")
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .accessibilityIdentifier("runControlSheet")
    }

    private var composerLiveRunTitle: String {
        if let orchestration = agentOrchestrationPresentation,
           orchestration.isActive {
            return orchestration.headline
        }
        if agentRunPresentation.isAccepting { return "Saving request" }
        if agentRunPresentation.isSynchronizing {
            return "Restoring activity"
        }
        if let group = agentRunPresentation.activeGroup,
           !group.state.isTerminal {
            return AgentActivityPresentation.humanizedVisibleText(
                group.summary,
                fallback: "Working"
            )
        }
        #if DEBUG
        if canaryOwnsSelectedConversation {
            switch hostedTextCanarySession.phase {
            case .accepting:
                return "Saving request"
            case .running:
                return "Hosted response"
            case .stopping:
                return "Stopping safely"
            case .blockedRecovery:
                return "Recovery required"
            case .idle:
                break
            }
        }
        #endif
        return AgentActivityPresentation.humanizedVisibleText(
            runtime.activityTitle,
            fallback: "Working"
        )
    }

    private func toggleComposerRunDetails() {
        if canonicalRunOwnsSelectedConversation {
            composerFocused = false
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            scrollAttachment = .restoring
            requestJumpToLatest(animated: true)
            return
        }
        #if DEBUG
        if canaryOwnsSelectedConversation {
            runtime.presentToast(
                "The hosted run receipt will appear in History after its durable projection finishes.",
                tone: .info
            )
            return
        }
        #endif
        composerFocused = false
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        showingRunDetails = true
    }

    private func stopActiveRun() {
        if agentOrchestrationPresentation?.isActive == true {
            Task { @MainActor in
                await agentSystemPresentation.cancelOrchestration(
                    scope: agentPresentationScope
                )
            }
            return
        }
        if let group = agentRunPresentation.activeGroup,
           group.accepts(group.cancelCommand) {
            handleActivityCommand(group.cancelCommand)
            return
        }
        #if DEBUG
        if canaryOwnsSelectedConversation,
           hostedTextCanarySession.phase != .blockedRecovery {
            hostedTextCanarySession.stop()
            return
        }
        #endif
        runtime.stopGenerating(context: modelContext)
    }

    private var shouldShowJumpToLatestAccessory: Bool {
        showJumpToLatest &&
            trimmedPrompt.isEmpty &&
            (!composerFocused || canonicalRunIsWorking ||
                (ownsActiveRunState && runtime.isWorking))
    }

    private var composerInputDisabled: Bool {
        hasForeignActiveRun ||
            hasForeignProjectMission ||
            providerSetupBlocksComposer ||
            hostedTextCanaryBlocksComposer ||
            canonicalRunIsActive ||
            (ownsActiveRunState && runtime.pendingTool != nil)
    }

    private var hostedTextCanaryBlocksComposer: Bool {
        #if DEBUG
        return hostedTextCanarySession.locksWorkspaceRouting
        #else
        return false
        #endif
    }

    private var composerCanSend: Bool {
        !trimmedPrompt.isEmpty &&
            !composerInputDisabled &&
            agentSystemPresentation.phase == .ready
    }

    private var composerPlaceholder: String {
        if hasForeignActiveRun { return "Open the running chat to send" }
        if hasForeignProjectMission { return "Project mission is already running" }
        #if DEBUG
        if canaryOwnsSelectedConversation {
            return hostedTextCanarySession.phase == .blockedRecovery
                ? "Recovery must finish before another request"
                : "Hosted request is already running"
        }
        #endif
        if ownsActiveRunState && runtime.pendingTool != nil { return "Approval needed before the next send" }
        if canonicalPendingApproval != nil { return "Approval needed before the next send" }
        if canonicalRunIsActive { return "NovaForge is finishing this run" }
        if ownsActiveRunState && runtime.isWorking { return "Queue a follow-up" }
        if missingCredentialSetup {
            return settings.provider == .openAICodex
                ? "Sign in with ChatGPT in Control"
                : "Add \(settings.provider.credentialDisplayName) key in Control"
        }
        if settings.provider == .local && needsLocalPowerUp { return "Download the local model, then ask" }
        return "What should NovaForge do?"
    }

    private var composerSendAccessibilityLabel: String {
        if agentSystemPresentation.phase != .ready {
            return "Send disabled while NovaForge restores the agent runtime"
        }
        if hasForeignActiveRun { return "Open running chat to send" }
        if hasForeignProjectMission { return "Send disabled while the project mission is active" }
        #if DEBUG
        if canaryOwnsSelectedConversation {
            return hostedTextCanarySession.phase == .blockedRecovery
                ? "Send disabled until hosted run recovery completes"
                : "Send disabled while the hosted request is active"
        }
        #endif
        if missingCredentialSetup {
            return settings.provider == .openAICodex
                ? "Send disabled until ChatGPT sign-in is complete"
                : "Send disabled until provider key is added"
        }
        if settings.provider == .local && needsLocalPowerUp { return "Send disabled until local model is downloaded" }
        if canonicalPendingApproval != nil { return "Send disabled while approval is pending" }
        if canonicalRunIsActive { return "Send disabled while the current run is active" }
        if ownsActiveRunState && runtime.pendingTool != nil { return "Send disabled while approval is pending" }
        return ownsActiveRunState && runtime.isWorking ? "Queue follow-up" : "Send message"
    }

    private var composerSendAccessibilityValue: String {
        #if DEBUG
        if debugSendDisposition.hasPrefix("rejected-") {
            return agentSystemPresentation.debugLastStartError
        }
        return "\(agentSystemPresentation.phase.rawValue)|\(debugSendDisposition)"
        #else
        return agentSystemPresentation.phase.rawValue
        #endif
    }

    private var composer: some View {
        let _ = AgentPerformance.bodyEvaluation("Chat Composer Body")
        let usesMultilineComposer = draftUsesExpandedComposer
        let fieldHeight: CGFloat = usesMultilineComposer ? 74 : 46
        let fieldMaxHeight: CGFloat = usesMultilineComposer ? 148 : 84
        let textLaneVerticalPadding: CGFloat = usesMultilineComposer ? 3 : 4
        let style = ComposerChromeStyle.default
        let canSendPrompt = composerCanSend
        let isQueueing = ownsActiveRunState && runtime.isWorking &&
            !hostedTextCanaryBlocksComposer
        let isMatrix = AgentTheme.current == .matrixRain
        let showsLiveRunRail = composerOwnsWorkingRun
        let composerMinHeight = showsLiveRunRail ? 108.0 : 112.0
        let composerMaxHeight = showsLiveRunRail ? 122.0 : 126.0
        let composerExpandedMaxHeight = style.expandedMaxHeight + (showsLiveRunRail ? 52 : 0)

        return VStack(alignment: .leading, spacing: showsLiveRunRail ? 4 : 0) {
                if showsLiveRunRail {
                    ComposerLiveRunRail(
                        title: composerLiveRunTitle,
                        expanded: showingRunDetails,
                        tint: chatChromeTint,
                        showDetails: toggleComposerRunDetails,
                        stop: stopActiveRun
                    )
                } else {
                    HStack(spacing: 8) {
                        ComposerModelPickerAnchor(
                            settings: settings,
                            localModels: runtime.localModels,
                            compact: false,
                            prepareToPresent: { composerFocused = false }
                        )
                        Spacer(minLength: 6)
                        ComposerReasoningControl(
                            provider: settings.provider,
                            modelID: settings.modelID
                        )
                    }
                    .padding(.horizontal, 2)
                }

                HStack(alignment: .bottom, spacing: 6) {
                    // Keep one native input alive for the entire draft. Swapping
                    // TextField for TextEditor at a character threshold destroys
                    // selection/IME state and was the reason the old code needed
                    // delayed focus-repair tasks on every long-prompt keystroke.
                    TextField(composerPlaceholder, text: $prompt, axis: .vertical)
                        .font(.system(.body, design: AgentPalette.interfaceFontDesign, weight: .regular))
                        .foregroundStyle(AgentPalette.ink)
                        .textFieldStyle(.plain)
                        .lineLimit(usesMultilineComposer ? 1...8 : 1...3)
                        .fixedSize(horizontal: false, vertical: true)
                        .focused($composerFocused)
                        .accessibilityIdentifier("chatComposer")
                        .submitLabel(.return)
                        .tint(chatChromeTint)
                        .frame(minHeight: fieldHeight, alignment: .topLeading)
                        .frame(maxHeight: fieldMaxHeight, alignment: .topLeading)
                        .padding(.leading, 12)
                        .padding(.trailing, 3)
                        .padding(.vertical, usesMultilineComposer ? 5 : 0)
                    .disabled(composerInputDisabled)
                    .opacity(composerInputDisabled ? 0.58 : 1)
                    .layoutPriority(1)

                    if shouldShowJumpToLatestAccessory {
                        JumpToLatestButton(tint: chatChromeTint, glassNamespace: glassNamespace) {
                            jumpToLatestFromAccessory()
                        }
                        .transition(.opacity.combined(with: .scale(scale: 0.92)))
                    }

                    ComposerSendButton(
                        title: nil,
                        isQueueing: isQueueing,
                        isEnabled: canSendPrompt,
                        tint: chatChromeTint,
                        accessibilityLabel: composerSendAccessibilityLabel,
                        accessibilityValue: composerSendAccessibilityValue,
                        action: sendPrompt
                    )
                    .frame(width: AgentDesign.minimumTouchTarget, height: AgentDesign.minimumTouchTarget)
                }
                .padding(.leading, 1)
                .padding(.trailing, 3)
                .padding(.vertical, textLaneVerticalPadding)
                .background {
                    RoundedRectangle(cornerRadius: 21, style: .continuous)
                        .fill(
                            LinearGradient(
	                                colors: [
	                                    AgentPalette.row.opacity(isMatrix ? (composerFocused ? 0.95 : 0.90) : (composerFocused ? 0.62 : 0.50)),
	                                    AgentPalette.surfaceAlt.opacity(isMatrix ? (composerFocused ? 0.72 : 0.62) : (composerFocused ? 0.24 : 0.16))
	                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 21, style: .continuous)
                        .strokeBorder(
                            LinearGradient(
                                colors: [
                                    AgentPalette.glassStroke.opacity(composerFocused ? 0.55 : 0.36),
                                    chatChromeTint.opacity(composerFocused ? 0.18 : 0.08)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: composerFocused ? 0.8 : 0.55
                        )
                }
                .shadow(color: chatChromeTint.opacity(composerFocused ? 0.025 : 0.010), radius: composerFocused ? 5 : 2, x: 0, y: 2)
            }
            .padding(.leading, style.leadingPadding)
            .padding(.trailing, style.trailingPadding)
            .padding(.vertical, style.verticalPadding)
            .frame(minHeight: composerMinHeight)
            .frame(maxHeight: usesMultilineComposer ? composerExpandedMaxHeight : composerMaxHeight, alignment: .bottom)
            .fixedSize(horizontal: false, vertical: true)
            .contentShape(RoundedRectangle(cornerRadius: style.cornerRadius, style: .continuous))
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Chat composer dock")
            .accessibilityIdentifier("chatComposerDock")
            .composerGlassSurface(focused: composerFocused, tint: chatChromeTint, style: style)
            .glassIDIfAvailable("composer", namespace: glassNamespace)
    }

    private var trimmedPrompt: String {
        prompt.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func handlePromptChanged() {
        #if DEBUG
        hostedTextCanaryDraftToken = UUID()
        #endif
        // If the user starts typing a fresh request after a failed run, get the
        // failure banner out of the composer path immediately. Retry/Continue stay
        // available until the user actually begins a new draft.
        if !canonicalRunOwnsSelectedConversation &&
            ownsActiveRunState && runtime.lastError != nil &&
            !trimmedPrompt.isEmpty {
            runtime.clearCurrentRunState(keepLastFailure: false)
        }
        if !trimmedPrompt.isEmpty, !hasActionableRunState {
            showingRunDetails = false
        }

        // Preserve pasted or typed multiline prompts. Coding requests often carry
        // stack traces, code blocks, or numbered instructions; sending the draft as
        // soon as a newline appears made the composer feel unstable and caused
        // accidental half-prompts. The explicit send button / submit action owns
        // sending now.
        if prompt.contains("\r\n") {
            prompt = prompt.replacingOccurrences(of: "\r\n", with: "\n")
            return
        }
    }

    private func sendPrompt() {
        #if DEBUG
        debugSendDisposition = "invoked"
        #endif
        let text = trimmedPrompt
        guard !text.isEmpty else {
            #if DEBUG
            debugSendDisposition = "empty"
            #endif
            return
        }
        guard !hasForeignActiveRun else {
            #if DEBUG
            debugSendDisposition = "foreign-run"
            #endif
            openActiveConversation()
            return
        }
        guard !hasForeignProjectMission else {
            #if DEBUG
            debugSendDisposition = "foreign-mission"
            #endif
            runtime.presentToast("Finish, stop, or approve the active project mission before starting another run here.", tone: .info)
            return
        }
        guard !canonicalRunIsActive,
              !(ownsActiveRunState && runtime.pendingTool != nil)
        else {
            #if DEBUG
            debugSendDisposition = "active-run"
            #endif
            return
        }
        AgentPerformance.event("Chat Prompt Send")
        let submittedDraft = prompt
        let submittedConversationID = conversation.id
        Task { @MainActor in
            let disposition = await agentSystemPresentation.startConfigured(
                prompt: text,
                conversation: conversation,
                project: scopedProject,
                workspace: agentWorkspace,
                settings: settings
            )
            switch disposition {
            case .accepted:
                #if DEBUG
                debugSendDisposition = "accepted"
                #endif
                if conversation.id == submittedConversationID,
                   prompt == submittedDraft {
                    prompt = ""
                    flushDraftPersistence("", for: submittedConversationID)
                    composerFocused = false
                    keyboard.reset()
                }
                forceScrollToBottom = true
                scrollAttachment = .restoring
                updateCachedMessages()
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                requestJumpToLatest(
                    animated: true,
                    delay: .milliseconds(60)
                )
            case .busy:
                #if DEBUG
                debugSendDisposition = "busy"
                #endif
                runtime.presentToast(
                    AgentSystemPresentationFailure.workspaceBusy.userMessage,
                    tone: .info
                )
                composerFocused = true
            case .rejected(let failure):
                #if DEBUG
                debugSendDisposition = "rejected-\(failure.rawValue)-\(agentSystemPresentation.debugLastStartError)"
                #endif
                runtime.presentToast(failure.userMessage, tone: .error)
                composerFocused = true
            }
        }
    }

    #if DEBUG
    private func sendHostedTextCanary(
        text: String,
        routing: AgentRunRoutingMetadata
    ) {
        guard !hostedTextCanarySession.locksWorkspaceRouting else { return }
        let requestMessageID = UUID()
        let draftToken = hostedTextCanaryDraftToken
        let history = conversation.messages
            .sorted(by: Self.messageAscending)
            .suffix(96)
            .filter {
                !runtime.queuedFollowUpMessageIDs.contains($0.id) &&
                    $0.runStatus != .queued
            }
            .map(\.providerInput)
        let workspaceSummary = ProviderContextWindow.workspaceSummary(
            for: runtime.workspace,
            provider: settings.provider
        )
        let request: AgentHostedTextCanaryLiveRequest
        do {
            request = try AgentHostedTextCanaryLiveRequest(
                routing: routing,
                selectedProvider: settings.provider,
                modelID: settings.modelID,
                temperature: settings.temperature,
                prompt: text,
                conversationID: conversation.id,
                projectID: scopedProject?.id,
                workspace: runtime.workspace,
                history: history,
                customSystemPrompt: settings.customSystemPrompt,
                workspaceSummary: workspaceSummary,
                requestMessageID: requestMessageID,
                draftToken: draftToken
            )
        } catch {
            runtime.presentToast(
                AgentHostedTextCanaryLiveNotice.requestInvalid.userMessage,
                tone: .error
            )
            composerFocused = true
            return
        }

        AgentPerformance.event("Hosted Text Canary Prompt Reserve")
        let disposition = hostedTextCanarySession.submit(
            request: request,
            container: modelContext.container,
            didAccept: { identity in
                let resolution = identity.persistenceResolution(
                    visibleConversationID: conversation.id,
                    visibleDraftToken: hostedTextCanaryDraftToken,
                    visibleText: trimmedPrompt,
                    persistedText: persistedDrafts()[
                        identity.conversationID.uuidString
                    ]
                )
                switch resolution {
                case .removeAndClearVisible:
                    flushDraftPersistence("", for: identity.conversationID)
                    prompt = ""
                    composerFocused = false
                    keyboard.reset()
                case .replacePersistedWithVisible:
                    // Durable acceptance raced a newer editor revision. Keep
                    // the new text both visible and crash-recoverable.
                    flushDraftPersistence(
                        prompt,
                        for: identity.conversationID
                    )
                case .removePersistedOnly:
                    // Navigation already flushed this conversation's editor.
                    // Remove only the accepted value and do not cancel the
                    // selected conversation's independent debounce task.
                    persistDraft("", for: identity.conversationID)
                case .preservePersisted:
                    // The background conversation already has a newer draft.
                    break
                }
                forceScrollToBottom = true
                scrollAttachment = .restoring
                updateCachedMessages()
                refreshDurableRunSnapshot()
                requestJumpToLatest(
                    animated: true,
                    delay: .milliseconds(60)
                )
            }
        )

        switch disposition {
        case .reserved:
            composerFocused = false
            keyboard.reset()
            forceScrollToBottom = true
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        case .busy:
            runtime.presentToast(
                "The hosted request is already active.",
                tone: .info
            )
        case .blockedRecovery:
            runtime.presentToast(
                AgentHostedTextCanaryLiveNotice.recoveryRequired.userMessage,
                tone: .error
            )
        }
    }

    private func handleHostedTextCanaryRevision() {
        updateCachedMessages()
        refreshDurableRunSnapshot()

        if let notice = hostedTextCanarySession.lastNotice,
           lastHostedTextCanaryNoticeRevision !=
               hostedTextCanarySession.revision {
            lastHostedTextCanaryNoticeRevision =
                hostedTextCanarySession.revision
            if notice == .cancelled {
                runtime.presentToast(notice.userMessage, tone: .info)
            } else {
                runtime.presentToast(notice.userMessage, tone: .error)
            }
            if notice == .routeUnavailable || notice == .credentialMissing ||
                notice == .credentialInvalid || notice == .requestInvalid {
                composerFocused = true
            }
        }

        if canaryIsActivelyWorking {
            forceScrollToBottom = true
            scrollAttachment = .restoring
            requestJumpToLatest(animated: true, delay: .milliseconds(60))
        } else if !hostedTextCanarySession.locksWorkspaceRouting {
            forceScrollToBottom = false
        }
    }
    #endif

    private func sendSuggestion(_ suggestion: QuickDelegateSuggestion) {
        sendPromptText(suggestion.prompt)
    }

    private func sendPromptText(_ text: String) {
        prompt = text
        sendPrompt()
    }

    private var shouldShowContextBar: Bool {
        guard ownsActiveRunState else { return false }
        if canonicalRunOwnsSelectedConversation { return false }
        // The Forge mission strip owns approval decisions. Keeping the old
        // compact run bar here would repeat the same state and could make its
        // non-actionable "Approve" badge look like the decision control.
        if canonicalPendingApproval != nil ||
            (runtime.pendingTool != nil && missionStripIsVisible) {
            return false
        }
        // Completed work is already stated in the assistant handoff and in
        // History. Keep the dock for states that still need a user decision.
        return hasActionableRunState
    }

    private var hasActionableRunState: Bool {
        guard ownsActiveRunState else { return false }
        if canonicalRunOwnsSelectedConversation {
            return canonicalRunIsActive ||
                agentRunPresentation.failure != nil ||
                agentRunPresentation.activeGroup?.state == .failed ||
                agentRunPresentation.activeGroup?.state == .cancelled ||
                agentRunPresentation.activeGroup?.state == .interrupted
        }
        return runtime.isWorking ||
            runtime.pendingTool != nil ||
            runtime.lastError != nil ||
            runtime.queuedPromptCount > 0 ||
            runtime.wasInterrupted
    }

    private var shouldShowQuickActions: Bool {
        return !shouldShowFirstRunGuides &&
        isNearChatBottom &&
        latestVisibleMessageSupportsQuickActions &&
        !composerFocused &&
        trimmedPrompt.isEmpty &&
        !canonicalRunIsActive &&
        canonicalPendingApproval == nil &&
        !runtime.isWorking &&
        runtime.pendingTool == nil &&
        runtime.lastError == nil &&
        runtime.queuedPromptCount == 0 &&
        !hostedTextCanaryBlocksComposer &&
        !showJumpToLatest &&
        hiddenMessageCount == 0 &&
        hasUserMessageInVisibleThread &&
        !hasForeignActiveRun
    }

    private var hasLatestJumpTarget: Bool {
        !cachedMessages.isEmpty ||
            (ownsActiveRunState && (canonicalRunIsWorking ||
                agentRunPresentation.liveText != nil || runtime.isWorking ||
                runtime.liveStream.isHandoffActive || runtime.hasTraceEvents ||
                cachedDurableRunSnapshot.hasCompletionEvidence))
    }

    private var shouldKeepTranscriptPinned: Bool {
        forceScrollToBottom || scrollAttachment == .restoring || scrollAttachment == .pinned
    }

    private func scheduleBottomDistanceUpdate(_ distance: CGFloat) {
        let threshold: CGFloat = AgentPerformance.isPerformanceMode ? 10 : 4
        if transient.lastReportedBottomDistance.isFinite,
           abs(transient.lastReportedBottomDistance - distance) <= threshold {
            return
        }
        transient.lastReportedBottomDistance = distance
        transient.bottomDistanceUpdateTask?.cancel()
        transient.bottomDistanceUpdateTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(AgentPerformance.isPerformanceMode ? 48 : 24))
            guard !Task.isCancelled else { return }
            updateBottomDistance(distance)
            AgentPerformance.value("Chat Scroll Bottom Distance", Double(distance))
        }
    }

    private func handleLayoutContractChange(oldValue: ChatLayoutContract, newValue: ChatLayoutContract) {
        guard oldValue != newValue else { return }
        AgentPerformance.event("Chat Layout Contract Update")
        AgentPerformance.value("Chat Keyboard Visible", newValue.keyboardVisible ? 1 : 0)
        AgentPerformance.value("Chat Accessory Bottom Padding", Double(newValue.accessoryBottomPadding))
        AgentPerformance.value("Chat Transcript Breathing Room", Double(newValue.transcriptBreathingRoom))
        guard shouldKeepTranscriptPinned else { return }
        scrollAttachment = .restoring
        requestJumpToLatest(animated: false, delay: .milliseconds(40))
    }

    private func handleRunStateChange(_ state: AgentRunState) {
        settleLiveStreamHandoff(animated: state == .waitingForApproval)
        switch state {
        case .completed, .cancelled, .failed(_):
            keepLatestReadableAfterAccessoryResize(animated: false)
        case .waitingForApproval:
            if shouldKeepTranscriptPinned {
                scrollAttachment = .restoring
                requestJumpToLatest(animated: true, delay: .milliseconds(80))
            }
        case .idle, .running:
            break
        }
    }

    private func settleLiveStreamHandoff(animated: Bool) {
        guard ownsActiveRunState, runtime.liveStream.handoffMessageID != nil else { return }
        updateCachedMessages()
        guard shouldKeepTranscriptPinned else { return }
        scrollAttachment = .restoring
        requestJumpToLatest(animated: animated, delay: .milliseconds(60))
    }

    private func keepLatestReadableAfterAccessoryResize(animated: Bool = true) {
        guard shouldKeepTranscriptPinned else { return }
        scrollAttachment = .restoring
        requestJumpToLatest(animated: animated)
        transient.accessoryResizeFollowUpTask?.cancel()
        transient.accessoryResizeFollowUpTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(180))
            guard shouldKeepTranscriptPinned else { return }
            requestJumpToLatest(animated: false)
        }
    }

    private func keepLiveStreamReadableDuringGrowth() {
        guard ownsActiveRunState,
              canonicalRunIsWorking || runtime.isWorking else { return }
        guard scrollAttachment != .detached else { return }
        let now = Date()
        guard now >= transient.userScrollIntentUntil,
              now >= transient.userDetachedUntil else { return }
        let minimumInterval: TimeInterval = AgentPerformance.isPerformanceMode ? 0.28 : 0.18
        guard now.timeIntervalSince(transient.lastLiveStreamJumpRequestAt) >= minimumInterval else { return }
        transient.lastLiveStreamJumpRequestAt = now
        scrollAttachment = .restoring
        requestJumpToLatest(animated: false)
    }

    private func updateBottomDistance(_ distance: CGFloat) {
        let now = Date()
        let isLiveRunGrowing = ownsActiveRunState &&
            (canonicalRunIsWorking || runtime.isWorking)
        let hasRecentUserScrollIntent = now < transient.userScrollIntentUntil

        if isLiveRunGrowing,
           scrollAttachment != .detached,
           !forceScrollToBottom,
           hasRecentUserScrollIntent,
           distance > detachedRepinThreshold {
            markUserDetached()
            return
        }

        if scrollAttachment == .detached {
            if now < transient.userDetachedUntil {
                return
            }

            if distance <= detachedRepinThreshold {
                scrollAttachment = .pinned
                transient.userDetachedUntil = .distantPast
                transient.userScrollIntentUntil = .distantPast
                AgentPerformance.event("Chat Scroll Pinned")
                return
            }

        }

        let activePinnedThreshold = ownsActiveRunState &&
            (canonicalRunIsWorking || runtime.isWorking) &&
            scrollAttachment != .detached
            ? max(bottomPinnedThreshold, 360)
            : bottomPinnedThreshold
        let nearBottom = distance <= activePinnedThreshold
        if nearBottom {
            if scrollAttachment != .pinned {
                scrollAttachment = .pinned
                AgentPerformance.event("Chat Scroll Pinned")
            }
        } else if !forceScrollToBottom && scrollAttachment != .detached {
            if isLiveRunGrowing && !hasRecentUserScrollIntent {
                if scrollAttachment != .restoring {
                    scrollAttachment = .restoring
                }
                requestJumpToLatest(animated: false, delay: .milliseconds(40))
            } else {
                scrollAttachment = .detached
                AgentPerformance.event("Chat Scroll Detached")
            }
        }
    }

    private func handleUserScrollGesture(_ value: DragGesture.Value) {
        // In a chat transcript, a downward finger drag means the user is pulling
        // away from the live bottom to read older content. Once that happens,
        // streaming/tool growth must stop forcing the scroll position until the
        // explicit Latest button is tapped.
        guard value.translation.height > 18 else { return }
        markUserDetached()
    }

    private func handleScrollPhaseChange(_ phase: ScrollPhase, context: ScrollPhaseChangeContext) {
        guard phase == .tracking || phase == .interacting || phase == .decelerating else { return }

        // A new gesture always wins over a pending one-shot Latest correction.
        transient.manualRepinTask?.cancel()

        let distance = max(0, context.geometry.contentSize.height - context.geometry.visibleRect.maxY)
        if distance <= detachedRepinThreshold {
            updateBottomDistance(distance)
            return
        }

        transient.userScrollIntentUntil = Date().addingTimeInterval(1.5)
        guard phase == .interacting || phase == .decelerating else { return }
        markUserDetached()
    }

    private func markUserDetached() {
        transient.manualRepinTask?.cancel()
        transient.scrollRequestTask?.cancel()
        transient.accessoryResizeFollowUpTask?.cancel()
        scrollAttachment = .detached
        forceScrollToBottom = false
        transient.userDetachedUntil = Date().addingTimeInterval(6)
        transient.userScrollIntentUntil = Date().addingTimeInterval(1.5)
        AgentPerformance.event("Chat Scroll Detached")
    }

    private func jumpToLatestFromAccessory() {
        transient.bottomDistanceUpdateTask?.cancel()
        transient.scrollRequestTask?.cancel()
        transient.manualRepinTask?.cancel()
        transient.userDetachedUntil = .distantPast
        transient.userScrollIntentUntil = .distantPast
        forceScrollToBottom = true
        scrollAttachment = .restoring
        requestJumpToLatest(animated: true)

        // One correction on the next settled layout is enough. It remains
        // cancellable, and the first new user drag cancels it immediately.
        transient.manualRepinTask = Task { @MainActor in
            do {
                try await Task.sleep(for: .milliseconds(140))
            } catch {
                return
            }
            guard !Task.isCancelled, scrollAttachment != .detached else { return }
            requestJumpToLatest(animated: false)
            await Task.yield()
            guard !Task.isCancelled, scrollAttachment != .detached else { return }
            forceScrollToBottom = false
            scrollAttachment = .pinned
        }
    }

    private func handleLatestMessageChange(
        oldValue: UUID?,
        newValue: UUID?
    ) {
        guard newValue != nil else { return }

        let shouldStayPinned = forceScrollToBottom || oldValue == nil || scrollAttachment != .detached
        if shouldStayPinned {
            scrollAttachment = .restoring
            requestJumpToLatest(animated: oldValue != nil)
        } else {
            scrollAttachment = .detached
        }
        forceScrollToBottom = false
    }

    private func scrollToLatest(_ proxy: ScrollViewProxy, animated: Bool) {
        guard scrollAttachment != .detached else { return }
        guard let targetID = latestScrollTargetID else { return }

        let action = {
            scrollAttachment = .restoring
            proxy.scrollTo(targetID, anchor: .bottom)
            forceScrollToBottom = false
            transient.userDetachedUntil = .distantPast
            transient.userScrollIntentUntil = .distantPast
            scrollAttachment = .pinned
        }

        if animated {
            withAnimation(shouldAnimateDecorative ? .smooth(duration: 0.28) : nil) {
                action()
            }
        } else {
            action()
        }
    }

    private func requestJumpToLatest(animated: Bool = true, delay: Duration? = nil) {
        transient.scrollRequestTask?.cancel()
        transient.scrollRequestTask = Task { @MainActor in
            if let delay {
                do {
                    try await Task.sleep(for: delay)
                } catch {
                    return
                }
            }
            guard !Task.isCancelled else { return }
            jumpToLatestAnimated = animated
            jumpToLatestRequest &+= 1
        }
    }

    private func toggleThreadWindow() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        withAnimation(.smooth(duration: 0.22)) {
            if hiddenMessageCount > 0 {
                messageRenderLimit = min(conversation.messageCount, messageRenderLimit + messageRenderWindowSize)
            } else {
                messageRenderLimit = messageRenderWindowSize
            }
        }
        updateCachedMessages()
    }

    private func openActiveConversation() {
        guard let conversation = activeElsewhereConversation else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        selectConversation(conversation)
    }
}

private enum ChatMode: Equatable {
    case idle
    case composing
    case streaming
    case toolRunning
    case pendingApproval
    case failed
    case completed
}

private enum ChatScrollAttachment: Equatable {
    case pinned
    case detached
    case restoring
}

private enum ChatComposerMode: Equatable {
    case compact
    case focused
    case expanded
    case disabled
}

private enum ChatRunAccessoryState: Equatable {
    case hidden
    case progress
    case approval
    case failure
}

private enum ChatTranscriptRow: Identifiable, Equatable {
    case message(ChatMessageSnapshot)
    case activity(AgentActivityGroup)
    case activityUnavailable(scopeID: String)
    case live(runID: RunID)

    var id: String {
        switch self {
        case .message(let message):
            return message.role == .assistant
                ? "response-\(message.id.uuidString)"
                : "message-\(message.id.uuidString)"
        case .activity(let group):
            return "activity-\(group.id.description)"
        case .activityUnavailable(let scopeID):
            return "activity-unavailable-\(scopeID)"
        case .live(let runID):
            return "live-run-\(runID.rawValue.uuidString)"
        }
    }

    var messageID: UUID? {
        switch self {
        case .message(let message):
            return message.id
        case .activity, .activityUnavailable, .live:
            return nil
        }
    }

    var assistantRunID: UUID? {
        guard case let .message(message) = self,
              message.role == .assistant
        else { return nil }
        return message.runID
    }

    static func precedes(_ lhs: Self, _ rhs: Self) -> Bool {
        if lhs.timestampMilliseconds != rhs.timestampMilliseconds {
            return lhs.timestampMilliseconds < rhs.timestampMilliseconds
        }
        if lhs.orderingRank != rhs.orderingRank {
            return lhs.orderingRank < rhs.orderingRank
        }
        return lhs.id < rhs.id
    }

    private var timestampMilliseconds: Int64 {
        switch self {
        case .message(let message):
            let milliseconds = message.createdAt.timeIntervalSince1970 * 1_000
            guard milliseconds.isFinite else { return 0 }
            return Int64(clamping: Int(milliseconds.rounded()))
        case .activity(let group):
            return group.span.startedAt.rawValue
        case .activityUnavailable:
            return Int64.max - 1
        case .live:
            return Int64.max
        }
    }

    private var orderingRank: Int {
        switch self {
        case .message(let message):
            switch message.role {
            case .user: return 0
            case .assistant: return 2
            case .tool: return 3
            case .system: return 4
            }
        case .activity: return 1
        case .activityUnavailable: return 3
        case .live: return 2
        }
    }
}

private struct CanonicalActivityUnavailableView: View {
    let openHistory: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.shield.fill")
                .foregroundStyle(AgentPalette.rose)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Activity receipt needs recovery")
                    .font(NovaType.headline)
                    .foregroundStyle(AgentPalette.ink)
                Text("Tool details are hidden until the canonical journal can be verified.")
                    .font(NovaType.caption)
                    .foregroundStyle(AgentPalette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 4)
            Button("History", action: openHistory)
                .buttonStyle(.bordered)
                .frame(minHeight: AgentDesign.minimumTouchTarget)
        }
        .padding(12)
        .agentGlass(radius: AgentDesign.rowRadius, tint: AgentPalette.rose.opacity(0.1))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("agentActivityUnavailable")
    }
}

@MainActor
private final class ChatTransientState: ObservableObject {
    var messageCacheGeneration = 0
    var messageCacheTask: Task<Void, Never>?
    var bottomDistanceUpdateTask: Task<Void, Never>?
    var accessoryResizeFollowUpTask: Task<Void, Never>?
    var scrollRequestTask: Task<Void, Never>?
    var manualRepinTask: Task<Void, Never>?
    var draftPersistenceTask: Task<Void, Never>?
    var lastLiveStreamJumpRequestAt = Date.distantPast
    var lastReportedBottomDistance: CGFloat = .infinity
    var userDetachedUntil = Date.distantPast
    var userScrollIntentUntil = Date.distantPast

    func cancelLayoutTasks() {
        bottomDistanceUpdateTask?.cancel()
        accessoryResizeFollowUpTask?.cancel()
        scrollRequestTask?.cancel()
        manualRepinTask?.cancel()
        draftPersistenceTask?.cancel()
    }
}

private struct ChatLayoutContract: Equatable {
    let keyboardVisible: Bool
    let composerMode: ChatComposerMode
    let runAccessory: ChatRunAccessoryState

    init(
        keyboardVisible: Bool = false,
        composerMode: ChatComposerMode = .compact,
        runAccessory: ChatRunAccessoryState = .hidden
    ) {
        self.keyboardVisible = keyboardVisible
        self.composerMode = composerMode
        self.runAccessory = runAccessory
    }

    var transcriptBreathingRoom: CGFloat {
        // The composer / Run Control stack is installed with safeAreaInset(edge: .bottom),
        // so SwiftUI already removes that chrome from the scroll viewport. Adding the
        // measured accessory height here double-counts the dock, makes scrollTo land on
        // an invisible spacer, and can leave the newest sent/assistant message stranded
        // off-screen below a large blank tail. Keep only a small visual gutter below the
        // latest-response anchor; the inset owns real composer clearance.
        switch runAccessory {
        case .hidden:
            return composerMode == .expanded ? 30 : 22
        case .progress:
            return 26
        case .approval, .failure:
            return 64
        }
    }

    var accessoryBottomPadding: CGFloat {
        keyboardVisible ? 10 : 8
    }
}

private struct ChatTranscriptBackdrop: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        let isMatrix = AgentTheme.current == .matrixRain
        let isLight = AgentPalette.isLight
        ZStack {
            LinearGradient(
                colors: [
                    AgentPalette.surface.opacity(isMatrix ? 0.18 : (isLight ? 0.22 : 0.34)),
                    AgentPalette.pearl.opacity(isMatrix ? 0.08 : (isLight ? 0.16 : 0.14)),
                    AgentPalette.surface.opacity(isMatrix ? 0.22 : (isLight ? 0.18 : 0.30))
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            if isMatrix && !reduceTransparency {
                Color.black.opacity(0.16)
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct ChatHeaderBackground: View {
    var body: some View {
        Color.clear
        .ignoresSafeArea(edges: .top)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct ChatDockBackground: View {
    var body: some View {
        // The transcript scrolls beneath the composer; without a backdrop its
        // raw text bleeds through the glass at full contrast and keeps going
        // into the dock gutter. Dissolve it into the theme canvas instead.
        LinearGradient(
            stops: [
                .init(color: AgentPalette.pearl.opacity(0), location: 0),
                .init(color: AgentPalette.pearl.opacity(AgentTheme.current == .matrixRain ? 0.90 : 0.84), location: 0.18),
                .init(color: AgentPalette.pearl.opacity(1.0), location: 0.64)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

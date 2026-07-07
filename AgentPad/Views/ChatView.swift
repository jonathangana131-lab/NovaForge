import SwiftData
import SwiftUI
import UIKit

struct ChatView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var runtime: AgentRuntime
    var project: Project
    var projects: [Project]
    var conversation: Conversation
    var conversations: [Conversation]
    var settings: AgentSettings
    let newChat: () -> Void
    let selectConversation: (Conversation) -> Void
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
    @State private var progressExpanded = false
    @State private var messageRenderLimit = 80
    @FocusState private var composerFocused: Bool
    @Namespace private var glassNamespace

    @State private var cachedMessages: [ChatMessageSnapshot] = []
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
    @State private var measuredAccessoryHeight: CGFloat = 0
    @State private var measuredBottomChromeCoverage: CGFloat = 0
    @StateObject private var keyboard = ChatKeyboardState()
    @AppStorage("codexTerminalPaired") private var codexTerminalPaired = false
    @AppStorage("novaForgeChatDraftsByConversation") private var persistedDraftsJSON = "{}"

    private static let chatLatestAnchorID = "chatLatestAnchor"
    private static let chatBottomID = "chatBottom"
    private static let chatScrollSpace = "chatScroll"
    private let messageRenderWindowSize = 80
    private let bottomPinnedThreshold: CGFloat = 160
    private let detachedRepinThreshold: CGFloat = 28
    private let latestResponseClearance: CGFloat = 64

    private var shouldAnimateDecorative: Bool {
        AgentPerformance.allowsDecorativeMotion && !reduceMotion
    }

    private var hiddenMessageCount: Int {
        let visibleCount = min(cachedSourceMessageCount, messageRenderLimit)
        return max(conversation.messageCount - visibleCount, 0)
    }

    private var showsCodexTerminalDemo: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("--codex-terminal-demo")
        #else
        false
        #endif
    }

    private var visibleMessages: ArraySlice<ChatMessageSnapshot> {
        guard messageRenderLimit > 0, cachedMessages.count > messageRenderLimit else {
            return cachedMessages[...]
        }
        return cachedMessages.suffix(messageRenderLimit)
    }

    private var transcriptRows: [ChatTranscriptRow] {
        var rows = visibleMessages.map(ChatTranscriptRow.message)
        guard shouldShowLiveResponseIsland else { return rows }

        let liveResponseID = runtime.liveStream.responseID
        let handoffMessageID = runtime.liveStream.handoffMessageID
        rows.removeAll { row in
            guard let messageID = row.messageID else { return false }
            return messageID == liveResponseID || messageID == handoffMessageID
        }

        let liveRow = ChatTranscriptRow.live(responseID: liveResponseID)
        if let firstQueuedFollowUpIndex = rows.firstIndex(where: { row in
            guard let messageID = row.messageID else { return false }
            return runtime.queuedFollowUpMessageIDs.contains(messageID)
        }) {
            rows.insert(liveRow, at: firstQueuedFollowUpIndex)
        } else {
            rows.append(liveRow)
        }
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
        !cachedMessages.isEmpty || (ownsActiveRunState && runtime.isWorking)
    }

    private var activeLayoutContract: ChatLayoutContract {
        ChatLayoutContract(
            accessoryHeight: measuredAccessoryHeight,
            bottomChromeCoverage: measuredBottomChromeCoverage,
            keyboardHeight: keyboard.isVisible ? keyboard.overlapHeight : 0,
            composerMode: composerMode,
            runAccessory: runAccessoryState
        )
    }

    private var chatMode: ChatMode {
        guard ownsActiveRunState else { return .idle }
        if runtime.pendingTool != nil { return .pendingApproval }
        if runtime.lastError != nil { return .failed }
        if runtime.isWorking { return .streaming }
        if composerFocused || !trimmedPrompt.isEmpty { return .composing }
        if hasCompletedRunEvidence { return .completed }
        return .idle
    }

    private var composerMode: ChatComposerMode {
        if hasForeignActiveRun || (ownsActiveRunState && runtime.pendingTool != nil) { return .disabled }
        if prompt.contains("\n") || prompt.count > 72 { return .expanded }
        if composerFocused { return .focused }
        return .compact
    }

    private var runAccessoryState: ChatRunAccessoryState {
        guard ownsActiveRunState else { return .hidden }
        if runtime.pendingTool != nil { return .approval }
        if runtime.lastError != nil || runtime.wasInterrupted { return .failure }
        if runtime.isWorking || runtime.queuedPromptCount > 0 { return .progress }
        // Completion banners only make sense above a transcript that actually
        // contains the completed work — never on a fresh, empty conversation.
        if hasCompletedRunEvidence && !cachedMessages.isEmpty { return .completion }
        return .hidden
    }

    private var hasCompletedRunEvidence: Bool {
        runtime.lastRunDuration != nil ||
            runtime.runState == .completed ||
            runtime.hasSuccessfulTraceEvent ||
            !runtime.currentArtifacts.isEmpty ||
            !cachedArtifacts.isEmpty ||
            cachedDurableRunSnapshot.hasCompletionEvidence
    }

    private var isNearChatBottom: Bool {
        scrollAttachment != .detached
    }

    private var showJumpToLatest: Bool {
        scrollAttachment == .detached && hasLatestJumpTarget
    }

    private var hasRenderedLiveHandoff: Bool {
        guard let handoffMessageID = runtime.liveStream.handoffMessageID else { return false }
        return cachedMessages.contains { $0.id == handoffMessageID }
    }

    private var shouldTopAnchorEmptyTranscript: Bool {
        cachedMessages.isEmpty &&
            !hasForeignActiveRun &&
            !(ownsActiveRunState && (runtime.isWorking || runtime.pendingTool != nil))
    }

    private var shouldShowLiveResponseIsland: Bool {
        ownsActiveRunState &&
            (runtime.isWorking || runtime.liveStream.isHandoffActive)
    }

    private var usesCompactStreamingComposer: Bool {
        AgentPerformance.prefersReducedVisualEffects &&
            ownsActiveRunState &&
            runtime.isWorking &&
            !composerFocused &&
            trimmedPrompt.isEmpty
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

    /// The local brain still needs installing (or resuming/repairing).
    /// `.checking` deliberately reads as ready so launch doesn't flash the
    /// power-up hero for users who already installed the model.
    private var needsLocalPowerUp: Bool {
        switch runtime.localModels.status {
        case .missing, .partial, .downloading, .failed, .incompatible: return true
        case .checking, .ready: return false
        }
    }

    private var missingCredentialSetup: Bool {
        settings.provider != .local &&
            !runtime.hasUsableProviderCredential(settings: settings)
    }

    private var providerSetupBlocksComposer: Bool {
        missingCredentialSetup || (settings.provider == .local && needsLocalPowerUp)
    }

    private var firstMissionReadiness: CleanChatEmptyState.Readiness {
        if missingCredentialSetup {
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
            title: "\(settings.provider.displayName) ready",
            detail: "Provider setup is complete. NovaForge can plan, run safe tools, and report proof.",
            symbol: settings.provider.symbol,
            tint: settings.provider.tint,
            actionTitle: nil,
            badgeTitle: "READY"
        )
    }

    private var shouldShowProjectStatusBoard: Bool {
        false
    }

    private var hasRunState: Bool {
        runtime.isWorking ||
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

    private var ownsActiveRunState: Bool {
        guard hasRunState else { return true }
        guard let activeConversationID = runtime.activeConversationID else { return true }
        return activeConversationID == conversation.id
    }

    private var hasForeignActiveRun: Bool {
        hasRunState && !ownsActiveRunState
    }

    private var activeElsewhereTitle: String {
        let title = runtime.activeConversationTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if title.isEmpty || title == LaunchConversationSelection.safeStartTitle {
            return "NovaForge"
        }
        return title
    }

    private var activeElsewhereConversation: Conversation? {
        guard let activeConversationID = runtime.activeConversationID else { return nil }
        return conversations.first { $0.id == activeConversationID }
    }

    private var conversationRefreshID: String {
        "\(conversation.id.uuidString)-\(conversation.messageCount)-\(conversation.updatedAt.timeIntervalSince1970)"
    }

    private var missionContractRefreshID: String {
        [
            project.id.uuidString,
            project.statusRawValue,
            String(project.updatedAt.timeIntervalSince1970),
            String(project.lastActivityAt.timeIntervalSince1970),
            String(conversation.updatedAt.timeIntervalSince1970),
            String(conversation.messageCount)
        ].joined(separator: "-")
    }

    private var durableRunRefreshID: String {
        let latestArtifactUpdate = project.artifacts
            .map(\.updatedAt.timeIntervalSince1970)
            .max() ?? 0
        let latestRunUpdate = project.toolRuns
            .map { ($0.completedAt ?? $0.createdAt).timeIntervalSince1970 }
            .max() ?? 0
        let latestFileChangeUpdate = project.fileChanges
            .map(\.createdAt.timeIntervalSince1970)
            .max() ?? 0
        let latestTerminalUpdate = project.terminalCommands
            .map(\.completedAt.timeIntervalSince1970)
            .max() ?? 0
        let latestProjectOSUpdate = project.projectOSRuns
            .map(\.updatedAt.timeIntervalSince1970)
            .max() ?? 0
        let latestEventUpdate = project.events
            .map(\.createdAt.timeIntervalSince1970)
            .max() ?? 0
        return [
            project.id.uuidString,
            String(project.toolRuns.count),
            String(project.artifacts.count),
            String(project.fileChanges.count),
            String(project.terminalCommands.count),
            String(project.projectOSRuns.count),
            String(project.events.count),
            String(latestRunUpdate),
            String(latestArtifactUpdate),
            String(latestFileChangeUpdate),
            String(latestTerminalUpdate),
            String(latestProjectOSUpdate),
            String(latestEventUpdate),
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
        let runtimeArtifacts = ownsActiveRunState ? runtime.currentArtifacts : []

        // In expanded-history mode, keep older assistant bubbles readable but avoid
        // re-parsing every historical markdown/code block on the render path.
        // The newest window still gets full markdown/code parsing.
        let parseAllMessages = fetchLimit <= messageRenderWindowSize
        let parseWindowSize = messageRenderWindowSize

        transient.messageCacheTask = Task {
            defer {
                AgentPerformance.end("Chat Message Cache", id: signpostID)
            }
            let snapshots = await Task.detached(priority: .userInitiated) {
                ChatMessageSnapshot.make(
                    from: sources,
                    parseAllMessages: parseAllMessages,
                    parseWindowSize: parseWindowSize
                )
            }.value
            guard !Task.isCancelled, transient.messageCacheGeneration == generation, conversation.id == conversationID else { return }
            if snapshots.count > previousCachedCount {
                AgentPerformance.event("Chat Message Append")
            }
            cachedMessages = snapshots
            cachedSourceMessageCount = sources.count
            updateCachedArtifacts(from: snapshots, runtimeArtifacts: runtimeArtifacts)
            if let handoffMessageID = runtime.liveStream.handoffMessageID,
               snapshots.contains(where: { $0.id == handoffMessageID }) {
                runtime.liveStream.clearHandoffIfRendered(messageID: handoffMessageID)
            }
        }
    }

    private func refreshMissionContract() {
        let signpostID = AgentPerformance.begin("Chat Mission Contract Build")
        let summary = ProjectMissionSummarizer.summarize(project: project, context: modelContext)
        cachedMissionContract = summary.missionContract
        cachedWorkflowSpine = summary.workflowSpine
        AgentPerformance.end("Chat Mission Contract Build", id: signpostID)
    }

    private func refreshDurableRunSnapshot() {
        cachedDurableRunSnapshot = ChatDurableRunSnapshot.make(
            project: project,
            conversation: conversation,
            context: modelContext
        )
        updateCachedArtifacts(from: cachedMessages)
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
        runtimeArtifacts: [WorkspaceArtifact]? = nil
    ) {
        var seen = Set<String>()
        var artifacts = runtimeArtifacts ?? runtime.currentArtifacts
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

    var body: some View {
        #if DEBUG
        if AgentPerformance.shouldProfileViewChanges {
            let _ = Self._printChanges()
        }
        #endif
        let _ = AgentPerformance.bodyEvaluation("Chat Body")
        GeometryReader { rootProxy in
            chatLayout(
                topSafeArea: rootProxy.safeAreaInsets.top,
                rootBottom: rootProxy.frame(in: .global).maxY
            )
        }
    }

    private func chatLayout(topSafeArea: CGFloat, rootBottom: CGFloat) -> some View {
        let _ = AgentPerformance.bodyEvaluation("Chat Layout")
        return ZStack {
            ChatTranscriptBackdrop()

            VStack(spacing: 0) {
                VStack(spacing: 9) {
                    ForgeHeader(
                        runtime: runtime,
                        project: project,
                        projects: projects,
                        scopedProject: scopedProject,
                        conversation: conversation,
                        settings: settings,
                        artifacts: cachedArtifacts,
                        durableSnapshot: cachedDurableRunSnapshot,
                        workflowSpine: cachedWorkflowSpine,
                        ownsActiveRunState: ownsActiveRunState,
                        hasForeignActiveRun: hasForeignActiveRun,
                        foreignActiveTitle: activeElsewhereTitle,
                        newChat: newChat,
                        changeScope: { selectedProject in
                            setConversationProjectScope(conversation, selectedProject)
                        },
                        createProject: createProject,
                        openWorkspaceSurface: openWorkspaceSurface,
                        openArtifact: previewArtifact,
                        openMissionDossier: openMissionDossier,
                        openChatDrawer: {
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            withAnimation(shouldAnimateDecorative ? .smooth(duration: 0.22) : nil) {
                                showingChatDrawer = true
                            }
                        }
                    )

                    if ForgeMissionStrip.isVisible(
                        scopedProject: scopedProject,
                        status: missionStatus,
                        autoContinue: missionAutoContinue
                    ) {
                        ForgeMissionStrip(
                            project: project,
                            scopedProject: scopedProject,
                            status: missionStatus,
                            autoContinue: missionAutoContinue,
                            approve: approveMissionTool,
                            reject: rejectMissionTool,
                            stop: stopMissionRun,
                            pauseAutoContinue: pauseMissionAutoContinue,
                            openDossier: openMissionDossier
                        )
                        .transition(.move(edge: .top).combined(with: .opacity))
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
                        ScrollView {
                            VStack(spacing: 0) {
                                LazyVStack(spacing: 14) {
                                    if shouldShowFirstRunGuides {
                                        EmptyView()
                                    }

                                    if shouldShowProjectStatusBoard {
                                        EmptyView()
                                    }

                                    if cachedMessages.isEmpty && !hasForeignActiveRun && !(ownsActiveRunState && (runtime.isWorking || runtime.pendingTool != nil)) {
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

                                    if settings.provider == .openAICodex && showsCodexTerminalDemo {
                                        CodexChatTerminalCard(isPaired: codexTerminalPaired) {
                                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                            openWorkspaceSurface(.settings)
                                        }
                                        .padding(.horizontal)
                                        .transition(.opacity)
                                    }

                                    ForEach(transcriptRows) { row in
                                        Group {
                                            switch row {
                                            case .message(let message):
                                                messageBubble(for: message)
                                            case .live:
                                                ChatLiveResponseIsland(
                                                    runtime: runtime,
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
                                    .id(Self.chatLatestAnchorID)

                                Color.clear
                                    .frame(height: transcriptBottomPadding)
                                    .accessibilityHidden(true)

                                Color.clear
                                    .frame(height: 1)
                                    .accessibilityHidden(true)
                                    .id(Self.chatBottomID)
                            }
                        }
                        .coordinateSpace(name: Self.chatScrollSpace)
                        .accessibilityIdentifier("chatTranscriptScroll")
                        .scrollContentBackground(.hidden)
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
                            let shouldInitialScroll = (ownsActiveRunState && runtime.isWorking) || forceScrollToBottom || !visibleMessages.isEmpty
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
                                settleLiveStreamHandoff(animated: true)
                            }
                        }
                        .onChange(of: runtime.runState) { _, newState in
                            handleRunStateChange(newState)
                        }
                        .onReceive(runtime.liveStream.objectWillChange) { _ in
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
                updateCachedArtifacts(from: cachedMessages, runtimeArtifacts: ownsActiveRunState ? runtime.currentArtifacts : [])
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
                transient.cancelLayoutTasks()
            }

        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            chatBottomAccessory
                .padding(.horizontal, 10)
                .padding(.top, 4)
                .padding(.bottom, accessoryBottomPadding)
                .background { ChatDockBackground() }
                .background {
                    GeometryReader { proxy in
                        Color.clear.preference(
                            key: ChatAccessoryGeometryPreferenceKey.self,
                            value: ChatAccessoryGeometry(
                                height: proxy.size.height,
                                minY: proxy.frame(in: .global).minY
                            )
                        )
                    }
                }
                .zIndex(5)
        }
        .overlay(alignment: .leading) {
            if showingChatDrawer {
                ChatDrawerOverlay(
                    project: project,
                    conversations: projectConversations,
                    selectedConversationID: conversation.id,
                    protectedConversationID: (runtime.isWorking || runtime.pendingTool != nil || runtime.queuedPromptCount > 0) ? (runtime.activeConversationID ?? conversation.id) : nil,
                    settings: settings,
                    selectConversation: { selected in
                        selectConversation(selected)
                    },
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
        .onChange(of: keyboard.revision) {
            guard keyboard.isVisible, shouldAutoScrollForKeyboard else { return }
            guard shouldKeepTranscriptPinned else { return }
            requestJumpToLatest(animated: true, delay: .milliseconds(80))
        }
        .onChange(of: projectResumeDraftRevision) {
            applyProjectResumeDraftIfNeeded(focusComposer: true)
        }
        .onChange(of: activeLayoutContract) { oldValue, newValue in
            handleLayoutContractChange(oldValue: oldValue, newValue: newValue)
        }
        .onChange(of: chatMode) {
            AgentPerformance.event("Chat Mode Update")
        }
        .onPreferenceChange(ChatAccessoryGeometryPreferenceKey.self) { geometry in
            scheduleAccessoryGeometryUpdate(geometry, rootBottom: rootBottom)
        }
        .animation(shouldAnimateDecorative ? .smooth(duration: 0.24) : nil, value: composerFocused)
        .animation(shouldAnimateDecorative ? .smooth(duration: 0.28) : nil, value: runtime.isWorking)
        .animation(shouldAnimateDecorative ? .smooth(duration: 0.24) : nil, value: hasForeignActiveRun)
        .animation(shouldAnimateDecorative ? .smooth(duration: 0.24) : nil, value: keyboard.revision)
        .onChange(of: conversation.id) { oldValue, _ in
            persistDraft(prompt, for: oldValue)
            prompt = ""
            selectedArtifact = nil
            composerFocused = false
            showingChatDrawer = false
            progressExpanded = false
            messageRenderLimit = messageRenderWindowSize
            measuredAccessoryHeight = 0
            measuredBottomChromeCoverage = 0
            transient.lastReportedBottomDistance = .infinity
            transient.accessoryResizeFollowUpTask?.cancel()
            transient.scrollRequestTask?.cancel()
            transient.manualRepinTask?.cancel()
            transient.manualRepinUntil = .distantPast
            keyboard.reset()
            scrollAttachment = .pinned
            forceScrollToBottom = conversation.messageCount > 0 || (ownsActiveRunState && runtime.isWorking)
            restorePersistedDraftIfAvailable()
        }
        .onChange(of: prompt) {
            handlePromptChanged()
            persistDraft(prompt, for: conversation.id)
        }
        .onChange(of: cachedSourceMessageCount) {
            if cachedSourceMessageCount <= messageRenderWindowSize {
                messageRenderLimit = messageRenderWindowSize
            }
            if hasLatestJumpTarget, shouldKeepTranscriptPinned {
                requestJumpToLatest()
            }
        }
        .sheet(item: Binding(get: { ownsActiveRunState ? runtime.pendingTool : nil }, set: { _ in })) { request in
            ApprovalSheet(
                request: request,
                approve: { runtime.approvePendingTool(conversation: conversation, settings: settings, context: modelContext, project: scopedProject) },
                reject: { runtime.rejectPendingTool(conversation: conversation, settings: settings, context: modelContext, project: scopedProject) },
                workspace: runtime.workspace
            )
            .presentationDetents([.fraction(0.68), .large])
            .presentationDragIndicator(.visible)
            .interactiveDismissDisabled(true)
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
            openArtifact: previewArtifact
        )
        .equatable()
        .id(message.id)
    }

    private func previewArtifact(_ artifact: WorkspaceArtifact) {
        AgentPerformance.event("Artifact Preview Open")
        ProjectEventRecorder.noteArtifactPreview(
            artifact,
            project: project,
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

    private func persistedDrafts() -> [String: String] {
        guard let data = persistedDraftsJSON.data(using: .utf8),
              let drafts = try? JSONDecoder().decode([String: String].self, from: data) else {
            return [:]
        }
        return drafts
    }

    private var chatBottomAccessory: some View {
        let _ = AgentPerformance.bodyEvaluation("Chat Bottom Accessory Body")
        return VStack(spacing: 6) {
            if hasForeignActiveRun {
                ActiveResponseElsewhereDock(title: activeElsewhereTitle, open: openActiveConversation)
            } else if shouldShowContextBar {
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
                    stop: { runtime.stopGenerating(context: modelContext) },
                    openWorkspaceSurface: openWorkspaceSurface,
                    clear: { runtime.clearCurrentRunState(keepLastFailure: false) },
                    expanded: $progressExpanded
                )
            } else if shouldShowQuickActions {
                QuickDelegateRail(
                    workflowSpine: scopedProject == nil ? nil : cachedWorkflowSpine,
                    send: sendSuggestion
                )
            }

            if shouldShowJumpToLatestAccessory {
                JumpToLatestButton(tint: chatChromeTint) {
                    jumpToLatestFromAccessory()
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.trailing, 18)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }

            composer
        }
        .padding(.horizontal, composerHorizontalPadding)
        .padding(.vertical, 6)
        .fixedSize(horizontal: false, vertical: true)
        .overlay(alignment: .topLeading) {
            Color.clear
                .frame(width: 1, height: 1)
                .allowsHitTesting(false)
                .accessibilityIdentifier(hasForeignActiveRun ? "activeResponseElsewhereDock" : "chatBottomAccessory")
        }
    }

    private var shouldShowJumpToLatestAccessory: Bool {
        showJumpToLatest &&
            trimmedPrompt.isEmpty &&
            (!composerFocused || (ownsActiveRunState && runtime.isWorking))
    }

    private var composerInputDisabled: Bool {
        hasForeignActiveRun ||
            providerSetupBlocksComposer ||
            (ownsActiveRunState && runtime.pendingTool != nil)
    }

    private var composerCanSend: Bool {
        !trimmedPrompt.isEmpty && !composerInputDisabled
    }

    private var composerPlaceholder: String {
        if hasForeignActiveRun { return "Open the running chat to send" }
        if ownsActiveRunState && runtime.pendingTool != nil { return "Approval needed before the next send" }
        if ownsActiveRunState && runtime.isWorking { return "Queue a follow-up" }
        if missingCredentialSetup { return "Add \(settings.provider.credentialDisplayName) key in Control" }
        if settings.provider == .local && needsLocalPowerUp { return "Download the local model, then ask" }
        return "Ask NovaForge"
    }

    private var composerSendAccessibilityLabel: String {
        if hasForeignActiveRun { return "Open running chat to send" }
        if missingCredentialSetup { return "Send disabled until provider key is added" }
        if settings.provider == .local && needsLocalPowerUp { return "Send disabled until local model is downloaded" }
        if ownsActiveRunState && runtime.pendingTool != nil { return "Send disabled while approval is pending" }
        return ownsActiveRunState && runtime.isWorking ? "Queue follow-up" : "Send message"
    }

    private var composerStatus: ComposerStatus {
        if hasForeignActiveRun {
            return ComposerStatus(title: "Elsewhere", symbol: "arrow.up.right.circle.fill", tint: AgentPalette.cyan)
        }
        if ownsActiveRunState && runtime.pendingTool != nil {
            return ComposerStatus(title: "Approval", symbol: "checkmark.shield.fill", tint: AgentPalette.cyan)
        }
        if ownsActiveRunState && runtime.isWorking {
            return ComposerStatus(title: trimmedPrompt.isEmpty ? "Running" : "Queue", symbol: trimmedPrompt.isEmpty ? "waveform" : "plus.message.fill", tint: chatChromeTint)
        }
        if missingCredentialSetup {
            return ComposerStatus(title: "Setup", symbol: "key.slash.fill", tint: AgentPalette.rose)
        }
        if settings.provider == .local && needsLocalPowerUp {
            return ComposerStatus(title: "Setup", symbol: "arrow.down.circle.fill", tint: AgentPalette.lilac)
        }
        if !trimmedPrompt.isEmpty {
            return ComposerStatus(title: prompt.contains("\n") || prompt.count > 72 ? "Long draft" : "Draft", symbol: "pencil.line", tint: AgentPalette.green)
        }
        if composerFocused {
            return ComposerStatus(title: "Ready", symbol: "sparkles", tint: chatChromeTint)
        }
        return ComposerStatus(title: "Ready", symbol: "sparkles", tint: AgentPalette.cyan)
    }

    private var composer: some View {
        let _ = AgentPerformance.bodyEvaluation("Chat Composer Body")
        let compactStreamingComposer = usesCompactStreamingComposer
        let usesMultilineComposer = !compactStreamingComposer && (prompt.contains("\n") || prompt.count > 28)
        let fieldHeight: CGFloat = compactStreamingComposer ? 40 : (usesMultilineComposer ? 74 : 46)
        let fieldMaxHeight: CGFloat = compactStreamingComposer ? 40 : (usesMultilineComposer ? 148 : 84)
        let textLaneVerticalPadding: CGFloat = compactStreamingComposer ? 2 : (usesMultilineComposer ? 3 : 4)
        let style = compactStreamingComposer ? ComposerChromeStyle.streamingCompact : .default
        let canSendPrompt = composerCanSend
        let isQueueing = ownsActiveRunState && runtime.isWorking
        let isMatrix = AgentTheme.current == .matrixRain

        return GlassGroup(spacing: compactStreamingComposer ? 8 : 12) {
            VStack(alignment: .leading, spacing: 3) {
                if !compactStreamingComposer {
                    HStack(spacing: 8) {
                        ComposerModelPickerAnchor(settings: settings)

                        Spacer(minLength: 0)

                        ComposerStatusPill(status: composerStatus)
                    }
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("composerActionRail")
                }

                HStack(alignment: .bottom, spacing: 6) {
                    Group {
                        if usesMultilineComposer {
                            TextEditor(text: $prompt)
                                .font(.system(size: 16, weight: .regular, design: AgentPalette.interfaceFontDesign))
                                .foregroundStyle(AgentPalette.ink)
                                .lineSpacing(2)
                                .scrollContentBackground(.hidden)
                                .background(Color.clear)
                                .focused($composerFocused)
                                .accessibilityIdentifier("chatComposer")
                                .tint(chatChromeTint)
                                .frame(minHeight: fieldHeight, idealHeight: 96, maxHeight: fieldMaxHeight, alignment: .topLeading)
                                .padding(.leading, 9)
                                .padding(.trailing, 3)
                                .padding(.vertical, 5)
                        } else {
                            TextField(composerPlaceholder, text: $prompt, axis: .vertical)
                                .font(.system(size: 16, weight: .regular, design: AgentPalette.interfaceFontDesign))
                                .foregroundStyle(AgentPalette.ink)
                                .textFieldStyle(.plain)
                                .lineLimit(1...3)
                                .fixedSize(horizontal: false, vertical: true)
                                .focused($composerFocused)
                                .accessibilityIdentifier("chatComposer")
                                .submitLabel(.return)
                                .tint(chatChromeTint)
                                .frame(minHeight: fieldHeight, alignment: .topLeading)
                                .frame(maxHeight: fieldMaxHeight, alignment: .topLeading)
                                .padding(.leading, 14)
                                .padding(.trailing, 3)
                                .padding(.vertical, 0)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if !composerInputDisabled {
                            composerFocused = true
                        }
                    }
                    .disabled(composerInputDisabled)
                    .opacity(composerInputDisabled ? 0.58 : 1)
                    .layoutPriority(1)

                    ComposerSendButton(
                        title: nil,
                        isQueueing: isQueueing,
                        isEnabled: canSendPrompt,
                        tint: chatChromeTint,
                        action: sendPrompt
                    )
                    .frame(width: 46, height: 46)
                    .disabled(!canSendPrompt)
                    .accessibilityLabel(composerSendAccessibilityLabel)
                    .accessibilityIdentifier("sendMessageButton")
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
            .frame(minHeight: style.minHeight)
            .frame(maxHeight: usesMultilineComposer ? style.expandedMaxHeight : style.collapsedMaxHeight, alignment: .bottom)
            .fixedSize(horizontal: false, vertical: true)
            .contentShape(RoundedRectangle(cornerRadius: style.cornerRadius, style: .continuous))
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("chatComposerDock")
            .onTapGesture {
                if !hasForeignActiveRun {
                    composerFocused = true
                }
            }
            .composerGlassSurface(focused: composerFocused, tint: chatChromeTint, style: style)
            .glassIDIfAvailable("composer", namespace: glassNamespace)
            .overlay {
                RoundedRectangle(cornerRadius: style.cornerRadius, style: .continuous)
                    .fill(Color.clear)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Chat composer dock")
                    .accessibilityIdentifier("chatComposerDock")
                    .allowsHitTesting(false)
            }
        }
        .accessibilityIdentifier("chatComposerDock")
        .animation(shouldAnimateDecorative ? .smooth(duration: 0.20) : nil, value: usesMultilineComposer)
        .animation(shouldAnimateDecorative ? .smooth(duration: 0.20) : nil, value: compactStreamingComposer)
        .animation(shouldAnimateDecorative ? .smooth(duration: 0.18) : nil, value: composerFocused)
        .animation(shouldAnimateDecorative ? .smooth(duration: 0.18) : nil, value: runtime.isWorking)
        .animation(shouldAnimateDecorative ? .smooth(duration: 0.18) : nil, value: hasForeignActiveRun)
    }

    private var trimmedPrompt: String {
        prompt.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func handlePromptChanged() {
        // If the user starts typing a fresh request after a failed run, get the
        // failure banner out of the composer path immediately. Retry/Continue stay
        // available until the user actually begins a new draft.
        if ownsActiveRunState && runtime.lastError != nil && !trimmedPrompt.isEmpty {
            runtime.clearCurrentRunState(keepLastFailure: false)
        }
        if !trimmedPrompt.isEmpty, !hasActionableRunState {
            progressExpanded = false
        }

        // Preserve pasted or typed multiline prompts. Coding requests often carry
        // stack traces, code blocks, or numbered instructions; sending the draft as
        // soon as a newline appears made the composer feel unstable and caused
        // accidental half-prompts. The explicit send button / submit action owns
        // sending now.
        if prompt.contains("\n") {
            prompt = prompt.replacingOccurrences(of: "\r\n", with: "\n")
        }
        if (prompt.contains("\n") || prompt.count > 38), composerFocused, !hasForeignActiveRun {
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(80))
                composerFocused = true
            }
        }
    }

    private func sendPrompt() {
        let text = trimmedPrompt
        guard !text.isEmpty else { return }
        guard !hasForeignActiveRun else {
            openActiveConversation()
            return
        }
        guard !(ownsActiveRunState && runtime.pendingTool != nil) else { return }
        AgentPerformance.event("Chat Prompt Send")
        if ownsActiveRunState && runtime.lastError != nil {
            runtime.clearCurrentRunState(keepLastFailure: false)
        }
        prompt = ""
        composerFocused = false
        keyboard.reset()
        forceScrollToBottom = true
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        runtime.send(prompt: text, conversation: conversation, settings: settings, context: modelContext, project: scopedProject)
        updateCachedMessages()
        scrollAttachment = .restoring
        requestJumpToLatest(animated: true, delay: .milliseconds(60))
    }

    private func sendSuggestion(_ suggestion: QuickDelegateSuggestion) {
        sendPromptText(suggestion.prompt)
    }

    private func sendPromptText(_ text: String) {
        prompt = text
        sendPrompt()
    }

    private var shouldShowContextBar: Bool {
        guard ownsActiveRunState else { return false }
        if hasActionableRunState { return true }
        guard !composerFocused, trimmedPrompt.isEmpty else { return false }
        // Completion evidence only earns the bar above a transcript that
        // actually contains the completed work. A fresh, empty conversation
        // stays clean — the welcome state owns that moment.
        return hasCompletedRunEvidence && !cachedMessages.isEmpty
    }

    private var hasActionableRunState: Bool {
        guard ownsActiveRunState else { return false }
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
        !runtime.isWorking &&
        runtime.pendingTool == nil &&
        runtime.lastError == nil &&
        runtime.queuedPromptCount == 0 &&
        !showJumpToLatest &&
        hiddenMessageCount == 0 &&
        hasUserMessageInVisibleThread &&
        !hasForeignActiveRun
    }

    private var hasLatestJumpTarget: Bool {
        !cachedMessages.isEmpty ||
            (ownsActiveRunState && (runtime.isWorking || runtime.liveStream.isHandoffActive || runtime.hasTraceEvents || cachedDurableRunSnapshot.hasCompletionEvidence))
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

    private func scheduleAccessoryGeometryUpdate(_ geometry: ChatAccessoryGeometry, rootBottom: CGFloat) {
        let sanitizedHeight = min(max(geometry.height, 0), keyboard.isVisible ? 260 : 492)
        let rawCoverage = rootBottom.isFinite && geometry.minY.isFinite
            ? rootBottom - geometry.minY
            : sanitizedHeight
        let sanitizedCoverage = min(max(rawCoverage, sanitizedHeight, 0), max(rootBottom, sanitizedHeight, 0))
        let threshold: CGFloat = AgentPerformance.isPerformanceMode ? 6 : 1
        let heightChanged = abs(measuredAccessoryHeight - sanitizedHeight) > threshold
        let coverageChanged = abs(measuredBottomChromeCoverage - sanitizedCoverage) > threshold
        guard heightChanged || coverageChanged else { return }
        transient.accessoryHeightUpdateTask?.cancel()
        transient.accessoryHeightUpdateTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(AgentPerformance.isPerformanceMode ? 48 : 24))
            guard !Task.isCancelled else { return }
            let heightChanged = abs(measuredAccessoryHeight - sanitizedHeight) > threshold
            let coverageChanged = abs(measuredBottomChromeCoverage - sanitizedCoverage) > threshold
            guard heightChanged || coverageChanged else { return }
            AgentPerformance.event("Composer Height Update")
            AgentPerformance.value("Composer Height", Double(sanitizedHeight))
            AgentPerformance.value("Chat Bottom Chrome Coverage", Double(sanitizedCoverage))
            measuredAccessoryHeight = sanitizedHeight
            measuredBottomChromeCoverage = sanitizedCoverage
            keepLatestReadableAfterAccessoryResize()
        }
    }

    private func handleLayoutContractChange(oldValue: ChatLayoutContract, newValue: ChatLayoutContract) {
        guard oldValue != newValue else { return }
        AgentPerformance.event("Chat Layout Contract Update")
        AgentPerformance.value("Chat Bottom Accessory Height", Double(newValue.accessoryHeight))
        AgentPerformance.value("Chat Keyboard Height", Double(newValue.keyboardHeight))
        AgentPerformance.value("Chat Accessory Bottom Padding", Double(newValue.accessoryBottomPadding))
        AgentPerformance.value("Chat Transcript Breathing Room", Double(newValue.transcriptBreathingRoom))
        guard shouldKeepTranscriptPinned else { return }
        scrollAttachment = .restoring
        requestJumpToLatest(animated: false, delay: .milliseconds(40))
    }

    private func handleRunStateChange(_ state: AgentRunState) {
        settleLiveStreamHandoff(animated: state != .waitingForApproval)
        switch state {
        case .completed, .cancelled, .failed(_):
            keepLatestReadableAfterAccessoryResize()
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

    private func keepLatestReadableAfterAccessoryResize() {
        guard shouldKeepTranscriptPinned else { return }
        scrollAttachment = .restoring
        requestJumpToLatest(animated: true)
        transient.accessoryResizeFollowUpTask?.cancel()
        transient.accessoryResizeFollowUpTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(180))
            guard shouldKeepTranscriptPinned else { return }
            requestJumpToLatest(animated: false)
        }
    }

    private func keepLiveStreamReadableDuringGrowth() {
        guard ownsActiveRunState, runtime.isWorking else { return }
        guard scrollAttachment != .detached else { return }
        let now = Date()
        guard now >= transient.userScrollIntentUntil,
              now >= transient.userDetachedUntil else { return }
        let minimumInterval: TimeInterval = AgentPerformance.isPerformanceMode ? 0.28 : 0.18
        guard now.timeIntervalSince(transient.lastLiveStreamJumpRequestAt) >= minimumInterval else { return }
        transient.lastLiveStreamJumpRequestAt = now
        scrollAttachment = .restoring
        requestJumpToLatest(animated: false, delay: .milliseconds(20))
    }

    private func updateBottomDistance(_ distance: CGFloat) {
        let now = Date()
        let isLiveRunGrowing = ownsActiveRunState && runtime.isWorking
        let hasRecentUserScrollIntent = now < transient.userScrollIntentUntil

        if now < transient.manualRepinUntil {
            if distance <= detachedRepinThreshold {
                scrollAttachment = .pinned
                forceScrollToBottom = false
                transient.manualRepinUntil = .distantPast
            } else {
                scrollAttachment = .restoring
            }
            return
        }

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

        let activePinnedThreshold = ownsActiveRunState && runtime.isWorking && scrollAttachment != .detached ? max(bottomPinnedThreshold, 360) : bottomPinnedThreshold
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
        guard ownsActiveRunState, runtime.isWorking else { return }
        // In a chat transcript, a downward finger drag means the user is pulling
        // away from the live bottom to read older content. Once that happens,
        // streaming/tool growth must stop forcing the scroll position until the
        // explicit Latest button is tapped.
        guard value.translation.height > 18 else { return }
        markUserDetached()
    }

    private func handleScrollPhaseChange(_ phase: ScrollPhase, context: ScrollPhaseChangeContext) {
        guard ownsActiveRunState, runtime.isWorking else { return }
        guard Date() >= transient.manualRepinUntil else {
            scrollAttachment = .restoring
            return
        }
        guard phase == .tracking || phase == .interacting || phase == .decelerating else { return }

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
        guard Date() >= transient.manualRepinUntil else {
            scrollAttachment = .restoring
            return
        }
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
        transient.manualRepinUntil = Date().addingTimeInterval(6)
        forceScrollToBottom = true
        scrollAttachment = .restoring
        requestJumpToLatest(animated: true)

        transient.manualRepinTask = Task { @MainActor in
            let followUps: [Duration] = [
                .milliseconds(140),
                .milliseconds(380),
                .milliseconds(900),
                .milliseconds(1_600),
                .milliseconds(2_400)
            ]
            for delay in followUps {
                do {
                    try await Task.sleep(for: delay)
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                requestJumpToLatest(animated: false)
            }

            do {
                try await Task.sleep(for: .milliseconds(180))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
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
        let action = {
            scrollAttachment = .restoring
            proxy.scrollTo(latestScrollTargetID ?? Self.chatBottomID, anchor: .bottom)
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
    case completion
}

private enum ChatTranscriptRow: Identifiable, Equatable {
    case message(ChatMessageSnapshot)
    case live(responseID: UUID)

    var id: String {
        switch self {
        case .message(let message):
            return "message-\(message.id.uuidString)"
        case .live(let responseID):
            return "live-\(responseID.uuidString)"
        }
    }

    var messageID: UUID? {
        switch self {
        case .message(let message):
            return message.id
        case .live:
            return nil
        }
    }
}

@MainActor
private final class ChatTransientState: ObservableObject {
    var messageCacheGeneration = 0
    var messageCacheTask: Task<Void, Never>?
    var bottomDistanceUpdateTask: Task<Void, Never>?
    var accessoryHeightUpdateTask: Task<Void, Never>?
    var accessoryResizeFollowUpTask: Task<Void, Never>?
    var scrollRequestTask: Task<Void, Never>?
    var manualRepinTask: Task<Void, Never>?
    var lastLiveStreamJumpRequestAt = Date.distantPast
    var lastReportedBottomDistance: CGFloat = .infinity
    var userDetachedUntil = Date.distantPast
    var userScrollIntentUntil = Date.distantPast
    var manualRepinUntil = Date.distantPast

    func cancelLayoutTasks() {
        bottomDistanceUpdateTask?.cancel()
        accessoryHeightUpdateTask?.cancel()
        accessoryResizeFollowUpTask?.cancel()
        scrollRequestTask?.cancel()
        manualRepinTask?.cancel()
    }
}

private struct ChatLayoutContract: Equatable {
    let accessoryHeight: CGFloat
    let bottomChromeCoverage: CGFloat
    let keyboardHeight: CGFloat
    let composerMode: ChatComposerMode
    let runAccessory: ChatRunAccessoryState

    init(
        accessoryHeight: CGFloat = 0,
        bottomChromeCoverage: CGFloat = 0,
        keyboardHeight: CGFloat = 0,
        composerMode: ChatComposerMode = .compact,
        runAccessory: ChatRunAccessoryState = .hidden
    ) {
        self.accessoryHeight = Self.quantize(accessoryHeight)
        self.bottomChromeCoverage = Self.quantize(bottomChromeCoverage)
        self.keyboardHeight = Self.quantize(keyboardHeight)
        self.composerMode = composerMode
        self.runAccessory = runAccessory
    }

    var isKeyboardVisible: Bool {
        keyboardHeight > 1
    }

    var transcriptBreathingRoom: CGFloat {
        let accessoryClearance = max(accessoryHeight, bottomChromeCoverage)
        switch runAccessory {
        case .hidden:
            return max(composerMode == .expanded ? 28 : 20, accessoryClearance + 18)
        case .progress, .completion:
            return max(58, accessoryClearance + 58)
        case .approval, .failure:
            return max(64, accessoryClearance + 64)
        }
    }

    var accessoryBottomPadding: CGFloat {
        isKeyboardVisible ? 10 : 8
    }

    private static func quantize(_ value: CGFloat) -> CGFloat {
        guard value.isFinite else { return 0 }
        return (value / 2).rounded(.toNearestOrAwayFromZero) * 2
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

private struct ChatAccessoryGeometry: Equatable {
    var height: CGFloat = 0
    var minY: CGFloat = .infinity
}

private struct ChatAccessoryGeometryPreferenceKey: PreferenceKey {
    static let defaultValue = ChatAccessoryGeometry()

    static func reduce(value: inout ChatAccessoryGeometry, nextValue: () -> ChatAccessoryGeometry) {
        value = nextValue()
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
                .init(color: AgentPalette.pearl.opacity(AgentTheme.current == .matrixRain ? 0.80 : 0.70), location: 0.28),
                .init(color: AgentPalette.pearl.opacity(1.0), location: 1)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .ignoresSafeArea(edges: .bottom)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

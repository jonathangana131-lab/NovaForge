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
    @State private var prompt = ""
    @State private var selectedArtifact: WorkspaceArtifact?
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

    private static let chatBottomID = "chatBottom"
    private static let chatScrollSpace = "chatScroll"
    private let messageRenderWindowSize = 80
    private let bottomPinnedThreshold: CGFloat = 160
    private let detachedRepinThreshold: CGFloat = 28

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

    private var projectConversations: [Conversation] {
        ChatProjectSeparation.visibleChatConversations(from: conversations).sorted { lhs, rhs in
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
        if hasCompletedRunEvidence { return .completion }
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
            sources = ordered.map(ChatMessageSource.init)
        } catch {
            sources = Self.recentMessageSources(from: conversation.messages, limit: fetchLimit)
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

    private nonisolated static func messageAscending(_ lhs: ChatMessage, _ rhs: ChatMessage) -> Bool {
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
                ChatHeaderView(
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
                    openWorkspaceSurface: openWorkspaceSurface,
                    openArtifact: previewArtifact,
                    openChatDrawer: {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        withAnimation(shouldAnimateDecorative ? .smooth(duration: 0.22) : nil) {
                            showingChatDrawer = true
                        }
                    }
                )
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

                                    if cachedMessages.isEmpty && !hasForeignActiveRun && !hasRunState {
                                        CleanChatEmptyState { starterPrompt in
                                            prompt = starterPrompt
                                            composerFocused = true
                                        }
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

                                    ForEach(visibleMessages) { message in
                                        messageBubble(for: message)
                                    }

                                    if ownsActiveRunState {
                                        ChatLiveResponseIsland(
                                            runtime: runtime,
                                            isVisibleForFrameProfiling: isVisibleForFrameProfiling
                                        )
                                        .id("liveResponse")
                                    }
                                }
                                .padding(.bottom, transcriptBottomPadding)
                                .padding(.top, 20)

                                Color.clear
                                    .frame(height: 1)
                                    .id(Self.chatBottomID)
                            }
                        }
                        .coordinateSpace(name: Self.chatScrollSpace)
                        .accessibilityIdentifier("chatTranscriptScroll")
                        .scrollContentBackground(.hidden)
                        .scrollDismissesKeyboard(.interactively)
                        // Layout-level bottom pinning: while the user is at the
                        // bottom, content growth (streaming text, tool rows)
                        // keeps the transcript pinned with NO scrollTo calls,
                        // no animation fights, and no per-flush layout jumps.
                        // Detach/re-pin is still governed by the scroll
                        // attachment state machine below.
                        .defaultScrollAnchor(.bottom, for: .initialOffset)
                        .defaultScrollAnchor(shouldKeepTranscriptPinned ? .bottom : nil, for: .sizeChanges)
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
                            let distance = max(0, geometry.contentSize.height - geometry.visibleRect.maxY)
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
                            }
                        }
                        .onChange(of: runtime.runState) { _, newState in
                            handleRunStateChange(newState)
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
                #if DEBUG
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
                #endif
                applyProjectResumeDraftIfNeeded(focusComposer: projectResumeDraftRevision > 0)
                restorePersistedDraftIfAvailable()
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
                reject: { runtime.rejectPendingTool(conversation: conversation, settings: settings, context: modelContext, project: scopedProject) }
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
        try? modelContext.save()
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
                    requestJumpToLatest()
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
        hasForeignActiveRun || (ownsActiveRunState && runtime.pendingTool != nil)
    }

    private var composerCanSend: Bool {
        !trimmedPrompt.isEmpty && !composerInputDisabled
    }

    private var composerPlaceholder: String {
        if hasForeignActiveRun { return "Open the running chat to send" }
        if ownsActiveRunState && runtime.pendingTool != nil { return "Approval needed before the next send" }
        if ownsActiveRunState && runtime.isWorking { return "Queue a follow-up" }
        if settings.provider == .local && !runtime.localModels.isDownloaded { return "Finish local model setup, then ask NovaForge" }
        return "Ask NovaForge"
    }

    private var composerSendAccessibilityLabel: String {
        if hasForeignActiveRun { return "Open running chat to send" }
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
        if settings.provider == .local && !runtime.localModels.isDownloaded {
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
        return hasCompletedRunEvidence
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
            (ownsActiveRunState && (runtime.isWorking || runtime.hasTraceEvents || cachedDurableRunSnapshot.hasCompletionEvidence))
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
        switch state {
        case .completed, .cancelled, .failed(_):
            keepLatestReadableAfterAccessoryResize()
        case .idle, .running, .waitingForApproval:
            break
        }
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

    private func updateBottomDistance(_ distance: CGFloat) {
        if ownsActiveRunState,
           runtime.isWorking,
           scrollAttachment != .detached,
           !forceScrollToBottom,
           Date() < transient.userScrollIntentUntil,
           distance > detachedRepinThreshold {
            markUserDetached()
            return
        }

        if scrollAttachment == .detached {
            if Date() < transient.userDetachedUntil {
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
            scrollAttachment = .detached
            AgentPerformance.event("Chat Scroll Detached")
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
        guard phase == .tracking || phase == .interacting || phase == .decelerating else { return }

        transient.userScrollIntentUntil = Date().addingTimeInterval(1.5)
        if phase == .interacting || phase == .decelerating {
            markUserDetached()
            return
        }

        let distance = max(0, context.geometry.contentSize.height - context.geometry.visibleRect.maxY)
        guard distance > detachedRepinThreshold else { return }
        markUserDetached()
    }

    private func markUserDetached() {
        scrollAttachment = .detached
        forceScrollToBottom = false
        transient.userDetachedUntil = Date().addingTimeInterval(6)
        transient.userScrollIntentUntil = Date().addingTimeInterval(1.5)
        AgentPerformance.event("Chat Scroll Detached")
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
            proxy.scrollTo(Self.chatBottomID, anchor: .bottom)
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

@MainActor
private final class ChatTransientState: ObservableObject {
    var messageCacheGeneration = 0
    var messageCacheTask: Task<Void, Never>?
    var bottomDistanceUpdateTask: Task<Void, Never>?
    var accessoryHeightUpdateTask: Task<Void, Never>?
    var accessoryResizeFollowUpTask: Task<Void, Never>?
    var scrollRequestTask: Task<Void, Never>?
    var lastLiveStreamJumpRequestAt = Date.distantPast
    var lastReportedBottomDistance: CGFloat = .infinity
    var userDetachedUntil = Date.distantPast
    var userScrollIntentUntil = Date.distantPast

    func cancelLayoutTasks() {
        bottomDistanceUpdateTask?.cancel()
        accessoryHeightUpdateTask?.cancel()
        accessoryResizeFollowUpTask?.cancel()
        scrollRequestTask?.cancel()
    }
}

private struct CleanChatEmptyState: View {
    var apply: (String) -> Void = { _ in }

    private static let starters: [(symbol: String, title: String, prompt: String)] = [
        ("hammer.fill", "Build something", "Build me a small SwiftUI view and save it to the workspace"),
        ("list.bullet.clipboard.fill", "Plan a mission", "Draft a step-by-step plan for my next feature and wait for my go"),
        ("doc.text.magnifyingglass", "Explore my files", "Summarize what is in my workspace right now")
    ]

    var body: some View {
        VStack(spacing: 18) {
            ZStack {
                Circle()
                    .fill(AgentPalette.primaryAccent.opacity(0.14))
                    .frame(width: 74, height: 74)
                    .blur(radius: 14)
                Circle()
                    .fill(AgentPalette.primaryAccent.opacity(0.10))
                    .frame(width: 58, height: 58)
                Image(systemName: "sparkles")
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(AgentPalette.primaryAccent)
            }

            VStack(spacing: 6) {
                Text("Ready when you are")
                    .font(.system(size: 19, weight: .black, design: AgentPalette.interfaceFontDesign))
                    .foregroundStyle(AgentPalette.ink)
                Text("Your on-device agent. Ask anything,\nor hand it a mission.")
                    .font(.system(size: 12.5, weight: .semibold, design: AgentPalette.interfaceFontDesign))
                    .foregroundStyle(AgentPalette.secondaryText)
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
            }

            VStack(spacing: 8) {
                ForEach(Self.starters, id: \.title) { starter in
                    Button {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        apply(starter.prompt)
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: starter.symbol)
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(AgentPalette.primaryAccent)
                                .frame(width: 24, height: 24)
                                .background(AgentPalette.primaryAccent.opacity(0.10), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                            Text(starter.title)
                                .font(.system(size: 13, weight: .bold, design: AgentPalette.interfaceFontDesign))
                                .foregroundStyle(AgentPalette.ink)
                            Spacer(minLength: 0)
                            Image(systemName: "arrow.up.right")
                                .font(.system(size: 10, weight: .black))
                                .foregroundStyle(AgentPalette.tertiaryText)
                        }
                        .padding(.horizontal, 13)
                        .frame(maxWidth: .infinity, minHeight: AgentDesign.minimumTouchTarget)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .agentRowSurface(radius: 15, tint: AgentPalette.primaryAccent)
                    .accessibilityLabel(starter.title)
                }
            }
            .frame(maxWidth: 340)
        }
        .padding(.top, 46)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, alignment: .center)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Clean chat ready")
        .accessibilityIdentifier("cleanChatEmptyState")
    }
}

private struct ActiveResponseElsewhereCard: View {
    let title: String
    let open: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            ProgressStatusIcon(tint: AgentPalette.cyan)
                .frame(width: 34, height: 34)

            VStack(alignment: .leading, spacing: 2) {
                Text("Active response")
                    .font(.system(size: 13, weight: .black, design: AgentPalette.interfaceFontDesign))
                    .foregroundStyle(AgentPalette.ink)
                Text("Running in \(title)")
                    .font(.system(size: 10.5, weight: .semibold, design: AgentPalette.interfaceFontDesign))
                    .foregroundStyle(AgentPalette.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 0)

            Button(action: open) {
                Image(systemName: "arrow.up.right.circle.fill")
                    .font(.system(size: 18, weight: .black))
                    .foregroundStyle(AgentPalette.cyan)
                    .frame(width: AgentDesign.minimumTouchTarget, height: AgentDesign.minimumTouchTarget)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open running chat")
        }
        .padding(12)
        .agentSurface(radius: 18, tint: AgentPalette.cyan.opacity(0.05))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("activeResponseElsewhereCard")
    }
}

private struct ActiveResponseElsewhereDock: View {
    let title: String
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: 9) {
                Image(systemName: "waveform")
                    .font(.system(size: 12, weight: .black))
                    .foregroundStyle(AgentPalette.cyan)
                Text("Running in \(title)")
                    .font(.system(size: 10.5, weight: .black, design: AgentPalette.interfaceFontDesign))
                    .foregroundStyle(AgentPalette.ink)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 10, weight: .black))
                    .foregroundStyle(AgentPalette.cyan)
            }
            .padding(.horizontal, 11)
            .frame(minHeight: 38)
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
        .agentControlSurface(radius: 13, tint: AgentPalette.cyan.opacity(0.10), selected: true)
        .accessibilityLabel("Active response is running in \(title). Open running chat.")
        .accessibilityIdentifier("activeResponseElsewhereDock")
    }
}

private struct ChatLiveResponseIsland: View {
    let runtime: AgentRuntime
    let isVisibleForFrameProfiling: Bool

    var body: some View {
        let _ = AgentPerformance.bodyEvaluation("Chat Live Response Island Body")
        let isWorking = runtime.isWorking
        let stream = runtime.liveStream
        ZStack(alignment: .topLeading) {
            LiveResponseView(isWorking: isWorking, stream: stream, runtime: runtime)

            if AgentPerformance.shouldProfileFrameRate {
                ChatStreamingFrameRateProbe(
                    stream: stream,
                    isWorking: isWorking,
                    isVisibleForFrameProfiling: isVisibleForFrameProfiling
                )
            }
        }
    }
}

private struct ChatStreamingFrameRateProbe: View {
    @ObservedObject var stream: LiveStreamBuffer
    let isWorking: Bool
    let isVisibleForFrameProfiling: Bool

    var body: some View {
        PerformanceFrameProbe(
            surface: .chatStreaming,
            isActive: isVisibleForFrameProfiling && (isWorking || !stream.isEmpty)
        )
        .frame(width: 0, height: 0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
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
        let accessoryClearance = max(accessoryHeight, bottomChromeCoverage) + 18
        switch runAccessory {
        case .hidden:
            return max(composerMode == .expanded ? 28 : 20, accessoryClearance)
        case .progress, .completion:
            return max(26, accessoryClearance)
        case .approval, .failure:
            return max(32, accessoryClearance)
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

@MainActor
final class ChatKeyboardState: ObservableObject {
    @Published private(set) var overlapHeight: CGFloat = 0
    @Published private(set) var minY: CGFloat = .greatestFiniteMagnitude
    @Published private(set) var revision = 0

    var isVisible: Bool {
        minY < .greatestFiniteMagnitude && overlapHeight > 1
    }

    func reset() {
        overlapHeight = 0
        minY = .greatestFiniteMagnitude
        revision &+= 1
    }

    init() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleKeyboardFrameChange(_:)),
            name: UIResponder.keyboardWillChangeFrameNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleKeyboardFrameChange(_:)),
            name: UIResponder.keyboardWillHideNotification,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func handleKeyboardFrameChange(_ notification: Notification) {
        let nextFrame = Self.keyboardFrame(from: notification)
        let nextHeight = Self.keyboardOverlap(for: nextFrame)
        let nextMinY = nextHeight > 1 ? nextFrame.minY : .greatestFiniteMagnitude
        guard abs(nextHeight - overlapHeight) > 0.5 || abs(nextMinY - minY) > 0.5 else { return }
        overlapHeight = nextHeight
        minY = nextMinY
        AgentPerformance.value("Keyboard Height", Double(nextHeight))
        revision &+= 1
    }

    private static func keyboardFrame(from notification: Notification) -> CGRect {
        notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect ?? .zero
    }

    private static func keyboardOverlap(for endFrame: CGRect) -> CGFloat {
        let window = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .filter { $0.activationState == .foregroundActive }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)

        let screenHeight = window?.bounds.height ?? endFrame.maxY
        let bottomSafeArea = window?.safeAreaInsets.bottom ?? 0
        return max(0, screenHeight - endFrame.minY - bottomSafeArea)
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
        Color.clear
            .ignoresSafeArea(edges: .bottom)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

private struct ComposerModelPickerAnchor: View {
    @Bindable var settings: AgentSettings

    var body: some View {
        ComposerModelMenu(settings: settings)
            .frame(minWidth: 124, maxWidth: 168, minHeight: 44, alignment: .leading)
            .contentShape(Capsule(style: .continuous))
    }
}

private struct ComposerStatus {
    let title: String
    let symbol: String
    let tint: Color
}

private struct ComposerStatusPill: View {
    let status: ComposerStatus

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: status.symbol)
                .font(.system(size: 10, weight: .black))
                .symbolRenderingMode(.hierarchical)
            Text(status.title)
                .font(.system(size: 9.5, weight: .black, design: AgentPalette.interfaceFontDesign))
                .lineLimit(1)
                .minimumScaleFactor(0.78)
        }
        .foregroundStyle(status.tint)
        .padding(.horizontal, 8)
        .frame(height: 24)
        .agentControlSurface(radius: 8, tint: status.tint.opacity(0.10), selected: true)
    }
}

private struct ComposerChromeStyle: Equatable {
    let cornerRadius: CGFloat
    let leadingPadding: CGFloat
    let trailingPadding: CGFloat
    let verticalPadding: CGFloat
    let minHeight: CGFloat
    let collapsedMaxHeight: CGFloat
    let expandedMaxHeight: CGFloat
    let surfaceOpacity: Double
    let focusedSurfaceOpacity: Double
    let tintOpacity: Double
    let focusedTintOpacity: Double
    let borderOpacity: Double
    let focusedBorderOpacity: Double
    let borderWidth: CGFloat
    let focusedBorderWidth: CGFloat
    let shadowOpacity: Double
    let focusedShadowOpacity: Double
    let shadowRadius: CGFloat
    let focusedShadowRadius: CGFloat
    let shadowY: CGFloat

    static let `default` = ComposerChromeStyle(
        cornerRadius: 27,
        leadingPadding: 9,
        trailingPadding: 9,
        verticalPadding: 4,
        minHeight: 96,
        collapsedMaxHeight: 108,
        expandedMaxHeight: 220,
        surfaceOpacity: 0.76,
        focusedSurfaceOpacity: 0.82,
        tintOpacity: 0.020,
        focusedTintOpacity: 0.052,
        borderOpacity: 0.16,
        focusedBorderOpacity: 0.30,
        borderWidth: 0.55,
        focusedBorderWidth: 0.85,
        shadowOpacity: 0.020,
        focusedShadowOpacity: 0.055,
        shadowRadius: 7,
        focusedShadowRadius: 12,
        shadowY: 4
    )

    static let streamingCompact = ComposerChromeStyle(
        cornerRadius: 24,
        leadingPadding: 8,
        trailingPadding: 8,
        verticalPadding: 4,
        minHeight: 62,
        collapsedMaxHeight: 72,
        expandedMaxHeight: 172,
        surfaceOpacity: 0.70,
        focusedSurfaceOpacity: 0.82,
        tintOpacity: 0.018,
        focusedTintOpacity: 0.052,
        borderOpacity: 0.14,
        focusedBorderOpacity: 0.30,
        borderWidth: 0.55,
        focusedBorderWidth: 0.85,
        shadowOpacity: 0.0,
        focusedShadowOpacity: 0.052,
        shadowRadius: 0,
        focusedShadowRadius: 11,
        shadowY: 3
    )
}

private struct ComposerGlassSurfaceModifier: ViewModifier {
    let focused: Bool
    let tint: Color
    let style: ComposerChromeStyle
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    @ViewBuilder
    func body(content: Content) -> some View {
        if reduceTransparency || AgentPlatformCompatibility.usesConservativeRendering {
            fallback(content: content)
        } else if #available(iOS 26.0, *) {
            glass(content: content)
        } else {
            fallback(content: content)
        }
    }

    private func decoratedContent(_ content: Content, includeSurfaceFill: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: style.cornerRadius, style: .continuous)
        let isMatrix = AgentTheme.current == .matrixRain
        let highlight = AgentPalette.glassStroke
        let surfaceOpacity = isMatrix ? (focused ? 0.98 : 0.94) : (focused ? style.focusedSurfaceOpacity : style.surfaceOpacity)
        return content
            .background {
                ZStack {
                    if includeSurfaceFill {
                        shape.fill(AgentPalette.surface.opacity(surfaceOpacity))
                    }
                    shape.fill(tint.opacity(focused ? style.focusedTintOpacity : style.tintOpacity))
                    shape.fill(
                        LinearGradient(
                            colors: [
                                highlight.opacity(isMatrix ? (focused ? 0.10 : 0.06) : (focused ? 0.24 : 0.16)),
                                Color.clear
                            ],
                            startPoint: .topLeading,
                            endPoint: .center
                        )
                    )
                }
                .allowsHitTesting(false)
            }
            .overlay {
                shape.strokeBorder(
                    LinearGradient(
                        colors: [
                            highlight.opacity(isMatrix ? (focused ? 0.20 : 0.12) : (focused ? style.focusedBorderOpacity : style.borderOpacity)),
                            tint.opacity(focused ? style.focusedBorderOpacity * 0.68 : style.borderOpacity * 0.56),
                            AgentPalette.border.opacity(style.borderOpacity)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: focused ? style.focusedBorderWidth : style.borderWidth
                )
                .allowsHitTesting(false)
            }
            .shadow(
                color: tint.opacity(focused ? style.focusedShadowOpacity : style.shadowOpacity),
                radius: focused ? style.focusedShadowRadius : style.shadowRadius,
                x: 0,
                y: focused ? style.shadowY + 1.5 : style.shadowY
            )
    }

    private func fallback(content: Content) -> some View {
        decoratedContent(content, includeSurfaceFill: true)
    }

    @available(iOS 26.0, *)
    private func glass(content: Content) -> some View {
        if AgentTheme.current == .matrixRain {
            return AnyView(fallback(content: content))
        }
        let shape = RoundedRectangle(cornerRadius: style.cornerRadius, style: .continuous)
        return AnyView(decoratedContent(content, includeSurfaceFill: false)
            .glassEffect(
                Glass.regular
                    .tint(tint.opacity(focused ? 0.13 : 0.07))
                    .interactive(),
                in: shape
            ))
    }
}

private extension View {
    func composerGlassSurface(focused: Bool, tint: Color, style: ComposerChromeStyle) -> some View {
        modifier(ComposerGlassSurfaceModifier(focused: focused, tint: tint, style: style))
    }

    @ViewBuilder
    func runContextSurface(usesPolishedSurface: Bool, tint: Color) -> some View {
        if usesPolishedSurface {
            agentSurface(radius: 18, tint: tint.opacity(0.07))
        } else {
            agentGlass(radius: 18, tint: tint.opacity(0.09))
        }
    }
}

private struct ChatFileChangeSnapshot: Identifiable, Equatable {
    let id: UUID
    let action: String
    let path: String
    let createdAt: Date

    init(change: ProjectFileChange) {
        id = change.id
        action = change.action
        path = change.path
        createdAt = change.createdAt
    }

    var displayAction: String {
        let trimmed = action.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "File changed" : trimmed
    }

    var displayPath: String {
        let name = URL(fileURLWithPath: path).lastPathComponent
        return name.isEmpty ? path : name
    }
}

private struct ChatProofSnapshot: Identifiable, Equatable {
    let id: String
    let title: String
    let detail: String
    let createdAt: Date
    let symbolName: String
    let sourcePath: String?
    let severity: ProjectEventSeverity

    init(item: ProjectProofItem) {
        id = item.id
        title = item.title
        detail = item.detail
        createdAt = item.createdAt
        symbolName = item.symbolName
        sourcePath = item.sourcePath
        severity = item.severity
    }
}

private struct ChatTerminalProofSnapshot: Identifiable, Equatable {
    let id: UUID
    let command: String
    let status: TerminalCommandStatus
    let completedAt: Date
    let outputPreview: String

    init(command: TerminalCommandRecord) {
        id = command.id
        self.command = command.command
        status = command.status
        completedAt = command.completedAt
        outputPreview = Self.preview(command.output)
    }

    private static func preview(_ output: String) -> String {
        let oneLine = output
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard oneLine.count > 96 else { return oneLine }
        return String(oneLine.prefix(96)) + "..."
    }
}

private struct ChatProjectOSRunSnapshot: Identifiable, Equatable {
    let id: UUID
    let status: ProjectOSRunStatus
    let currentAction: String
    let nextStep: String
    let resumeState: String
    let proofSummary: String
    let changedFilesSummary: String
    let updatedAt: Date
    let recommendedAction: String

    init(run: ProjectOSRun) {
        id = run.id
        status = run.status
        currentAction = run.currentAction
        nextStep = run.nextStep
        resumeState = run.resumeState
        proofSummary = run.proofSummary
        changedFilesSummary = run.changedFilesSummary
        updatedAt = run.updatedAt
        recommendedAction = run.currentIntent.recommendedAction
    }

    var hasResumeCue: Bool {
        status == .stopped ||
            status == .blocked ||
            status == .failed ||
            !resumeState.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var displayTitle: String {
        if hasResumeCue { return "Resume available" }
        switch status {
        case .planning, .running:
            return "ProjectOS active"
        case .waiting:
            return "ProjectOS waiting"
        case .completed:
            return "ProjectOS complete"
        case .blocked:
            return "ProjectOS blocked"
        case .failed:
            return "ProjectOS failed"
        case .stopped:
            return "ProjectOS stopped"
        case .idle:
            return "ProjectOS ready"
        }
    }

    var displayDetail: String {
        for candidate in [resumeState, currentAction, recommendedAction, nextStep] {
            let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return status.displayName
    }
}

private struct ChatDurableRunSnapshot: Equatable {
    var artifacts: [WorkspaceArtifact]
    var traceEvents: [AgentTraceEvent]
    var fileChanges: [ChatFileChangeSnapshot]
    var pendingApprovalCount: Int
    var latestProof: ChatProofSnapshot?
    var latestTerminalProof: ChatTerminalProofSnapshot?
    var projectOSRun: ChatProjectOSRunSnapshot?
    var reviewHeadline: String
    var reviewDetail: String
    var proofFreshness: String
    var evidenceTrail: String
    var lastRunDuration: TimeInterval?
    var hasCompletedRun: Bool

    static let empty = ChatDurableRunSnapshot(
        artifacts: [],
        traceEvents: [],
        fileChanges: [],
        pendingApprovalCount: 0,
        latestProof: nil,
        latestTerminalProof: nil,
        projectOSRun: nil,
        reviewHeadline: "",
        reviewDetail: "",
        proofFreshness: "",
        evidenceTrail: "",
        lastRunDuration: nil,
        hasCompletedRun: false
    )

    var hasCompletionEvidence: Bool {
        hasCompletedRun ||
            lastRunDuration != nil ||
            !artifacts.isEmpty ||
            !fileChanges.isEmpty ||
            latestProof != nil ||
            latestTerminalProof != nil ||
            projectOSRun?.hasResumeCue == true ||
            traceEvents.contains { $0.status == .success }
    }

    static func make(
        project: Project,
        conversation: Conversation,
        context: ModelContext
    ) -> ChatDurableRunSnapshot {
        let fetchedArtifacts = fetchRecentArtifacts(context: context)
        let fetchedRuns = fetchRecentToolRuns(context: context)
        let fetchedFileChanges = fetchRecentFileChanges(context: context)
        let fetchedTerminalCommands = fetchRecentTerminalCommands(context: context)
        let fetchedProjectOSRuns = fetchRecentProjectOSRuns(context: context)
        let summary = ProjectMissionSummarizer.summarize(project: project, context: context)
        let projectID = project.id
        let allowsOrphanFallback = conversationSuggestsRecentRun(conversation)

        let latestArtifacts = uniqueArtifacts(
            project.artifacts +
                fetchedArtifacts.filter { $0.project?.id == projectID } +
                (allowsOrphanFallback ? fetchedArtifacts.filter { $0.project == nil } : [])
        ).sorted { lhs, rhs in
            if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
            return lhs.path < rhs.path
        }
        let latestRuns = uniqueRuns(
            project.toolRuns +
                fetchedRuns.filter { $0.project?.id == projectID } +
                (allowsOrphanFallback ? fetchedRuns.filter { $0.project == nil } : [])
        ).sorted { lhs, rhs in
            let lhsDate = lhs.completedAt ?? lhs.createdAt
            let rhsDate = rhs.completedAt ?? rhs.createdAt
            if lhsDate != rhsDate { return lhsDate > rhsDate }
            return lhs.id.uuidString < rhs.id.uuidString
        }
        let latestFileChanges = uniqueFileChanges(
            project.fileChanges +
                fetchedFileChanges.filter { $0.project?.id == projectID } +
                (allowsOrphanFallback ? fetchedFileChanges.filter { $0.project == nil } : [])
        ).sorted { lhs, rhs in
            if lhs.createdAt != rhs.createdAt { return lhs.createdAt > rhs.createdAt }
            return lhs.path < rhs.path
        }
        let latestTerminalCommands = uniqueTerminalCommands(
            project.terminalCommands +
                fetchedTerminalCommands.filter { $0.project?.id == projectID } +
                (allowsOrphanFallback ? fetchedTerminalCommands.filter { $0.project == nil } : [])
        ).sorted { lhs, rhs in
            if lhs.completedAt != rhs.completedAt { return lhs.completedAt > rhs.completedAt }
            return lhs.id.uuidString < rhs.id.uuidString
        }
        let latestProjectOSRun = uniqueProjectOSRuns(
            project.projectOSRuns +
                fetchedProjectOSRuns.filter { $0.project?.id == projectID }
        ).sorted { lhs, rhs in
            if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
            return lhs.id.uuidString < rhs.id.uuidString
        }.first

        var seenArtifactPaths = Set<String>()
        var artifacts: [WorkspaceArtifact] = []
        for artifact in latestArtifacts {
            guard seenArtifactPaths.insert(artifact.path).inserted else { continue }
            artifacts.append(WorkspaceArtifact(path: artifact.path))
            if artifacts.count >= 4 { break }
        }
        if artifacts.count < 4 {
            for run in latestRuns {
                guard let artifact = WorkspaceArtifact.fromToolOutput(run.output),
                      seenArtifactPaths.insert(artifact.path).inserted else { continue }
                artifacts.append(artifact)
                if artifacts.count >= 4 { break }
            }
        }

        var traceEvents = latestRuns.prefix(6).map(Self.traceEvent)
        if traceEvents.isEmpty, let artifact = artifacts.first {
            traceEvents.append(AgentTraceEvent(
                title: "Run complete",
                detail: artifact.path,
                status: .success
            ))
        }

        let latestCompletedRun = latestRuns.first { run in
            run.completedAt != nil && (run.status == .completed || run.status == .failed || run.status == .rejected)
        }
        let duration = latestCompletedRun.flatMap { run -> TimeInterval? in
            guard let completedAt = run.completedAt else { return nil }
            return completedAt.timeIntervalSince(run.createdAt)
        }

        return ChatDurableRunSnapshot(
            artifacts: artifacts,
            traceEvents: Array(traceEvents.prefix(6)),
            fileChanges: latestFileChanges.prefix(5).map { ChatFileChangeSnapshot(change: $0) },
            pendingApprovalCount: summary.pendingApprovalCount,
            latestProof: summary.proofItems.first.map { ChatProofSnapshot(item: $0) },
            latestTerminalProof: latestTerminalCommands.first.map { ChatTerminalProofSnapshot(command: $0) },
            projectOSRun: latestProjectOSRun.map { ChatProjectOSRunSnapshot(run: $0) },
            reviewHeadline: summary.review.headline,
            reviewDetail: summary.review.detail,
            proofFreshness: summary.review.proofFreshness,
            evidenceTrail: summary.review.evidenceTrail,
            lastRunDuration: duration,
            hasCompletedRun: latestRuns.contains { $0.status == .completed }
        )
    }

    static func mergedTraceEvents(
        runtime: [AgentTraceEvent],
        durable: [AgentTraceEvent],
        limit: Int = 6
    ) -> [AgentTraceEvent] {
        var seen = Set<String>()
        var events: [AgentTraceEvent] = []
        for event in runtime + durable {
            let key = "\(event.title)|\(event.detail)|\(event.status.rawValue)"
            guard seen.insert(key).inserted else { continue }
            events.append(event)
            if events.count >= limit { break }
        }
        return events
    }

    private static func traceEvent(for run: ToolRun) -> AgentTraceEvent {
        AgentTraceEvent(
            title: traceTitle(for: run),
            detail: traceDetail(for: run),
            status: traceStatus(for: run.status)
        )
    }

    private static func traceTitle(for run: ToolRun) -> String {
        switch run.status {
        case .pendingApproval:
            return "Queued \(run.name)"
        case .approved:
            return "Approved \(run.name)"
        case .rejected:
            return "Rejected \(run.name)"
        case .completed:
            return run.requiresApproval ? "Approved \(run.name)" : "Finished \(run.name)"
        case .failed:
            return "Failed \(run.name)"
        }
    }

    private static func traceDetail(for run: ToolRun) -> String {
        if run.status == .failed, !run.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return run.output
        }
        if !run.argumentsJSON.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return run.argumentsJSON
        }
        return run.output
    }

    private static func traceStatus(for status: ToolRunStatus) -> AgentTraceStatus {
        switch status {
        case .pendingApproval, .approved:
            return .approval
        case .rejected, .failed:
            return .failed
        case .completed:
            return .success
        }
    }

    private static func fetchRecentArtifacts(context: ModelContext) -> [ProjectArtifact] {
        var descriptor = FetchDescriptor<ProjectArtifact>(
            sortBy: [SortDescriptor(\ProjectArtifact.updatedAt, order: .reverse)]
        )
        descriptor.fetchLimit = 24
        return (try? context.fetch(descriptor)) ?? []
    }

    private static func fetchRecentToolRuns(context: ModelContext) -> [ToolRun] {
        var descriptor = FetchDescriptor<ToolRun>(
            sortBy: [SortDescriptor(\ToolRun.createdAt, order: .reverse)]
        )
        descriptor.fetchLimit = 24
        return (try? context.fetch(descriptor)) ?? []
    }

    private static func fetchRecentFileChanges(context: ModelContext) -> [ProjectFileChange] {
        var descriptor = FetchDescriptor<ProjectFileChange>(
            sortBy: [SortDescriptor(\ProjectFileChange.createdAt, order: .reverse)]
        )
        descriptor.fetchLimit = 24
        return (try? context.fetch(descriptor)) ?? []
    }

    private static func fetchRecentTerminalCommands(context: ModelContext) -> [TerminalCommandRecord] {
        var descriptor = FetchDescriptor<TerminalCommandRecord>(
            sortBy: [SortDescriptor(\TerminalCommandRecord.completedAt, order: .reverse)]
        )
        descriptor.fetchLimit = 24
        return (try? context.fetch(descriptor)) ?? []
    }

    private static func fetchRecentProjectOSRuns(context: ModelContext) -> [ProjectOSRun] {
        var descriptor = FetchDescriptor<ProjectOSRun>(
            sortBy: [SortDescriptor(\ProjectOSRun.updatedAt, order: .reverse)]
        )
        descriptor.fetchLimit = 12
        return (try? context.fetch(descriptor)) ?? []
    }

    private static func uniqueArtifacts(_ artifacts: [ProjectArtifact]) -> [ProjectArtifact] {
        var seen = Set<String>()
        var result: [ProjectArtifact] = []
        for artifact in artifacts {
            guard seen.insert(artifact.path).inserted else { continue }
            result.append(artifact)
        }
        return result
    }

    private static func uniqueRuns(_ runs: [ToolRun]) -> [ToolRun] {
        var seen = Set<UUID>()
        var result: [ToolRun] = []
        for run in runs {
            guard seen.insert(run.id).inserted else { continue }
            result.append(run)
        }
        return result
    }

    private static func uniqueFileChanges(_ changes: [ProjectFileChange]) -> [ProjectFileChange] {
        var seen = Set<UUID>()
        var result: [ProjectFileChange] = []
        for change in changes {
            guard seen.insert(change.id).inserted else { continue }
            result.append(change)
        }
        return result
    }

    private static func uniqueTerminalCommands(_ commands: [TerminalCommandRecord]) -> [TerminalCommandRecord] {
        var seen = Set<UUID>()
        var result: [TerminalCommandRecord] = []
        for command in commands {
            guard seen.insert(command.id).inserted else { continue }
            result.append(command)
        }
        return result
    }

    private static func uniqueProjectOSRuns(_ runs: [ProjectOSRun]) -> [ProjectOSRun] {
        var seen = Set<UUID>()
        var result: [ProjectOSRun] = []
        for run in runs {
            guard seen.insert(run.id).inserted else { continue }
            result.append(run)
        }
        return result
    }

    private static func conversationSuggestsRecentRun(_ conversation: Conversation) -> Bool {
        conversation.messages.suffix(8).contains { message in
            if message.role == .tool { return true }
            let text = message.content.lowercased()
            return text.contains("run complete") ||
                text.contains("artifact") ||
                text.contains("playable game ready") ||
                text.contains("approval demo")
        }
    }
}

private struct JumpToLatestButton: View {
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            action()
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "arrow.down")
                    .font(.system(size: 11, weight: .black))
                Text("Latest")
                    .font(.system(size: 11, weight: .bold, design: AgentPalette.interfaceFontDesign))
            }
            .foregroundStyle(AgentPalette.ink)
            .padding(.horizontal, 12)
            .frame(height: AgentDesign.minimumTouchTarget)
            .agentGlass(radius: 14, interactive: true, tint: tint.opacity(0.14))
            .shadow(color: tint.opacity(0.16), radius: 10, x: 0, y: 5)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("jumpToLatest")
        .accessibilityLabel("Jump to latest message")
    }
}

private struct QuickDelegateSuggestion: Identifiable {
    let id: String
    let title: String
    let symbol: String
    let prompt: String
    let tint: Color
}

private struct QuickDelegateRail: View {
    let workflowSpine: ProjectWorkflowSpine?
    let send: (QuickDelegateSuggestion) -> Void

    private var suggestions: [QuickDelegateSuggestion] {
        if let workflowSpine {
            return [
                QuickDelegateSuggestion(
                    id: "continue",
                    title: "Continue",
                    symbol: "arrow.triangle.2.circlepath",
                    prompt: workflowSpine.nextActionDetail,
                    tint: AgentPalette.green
                ),
                QuickDelegateSuggestion(
                    id: "iterate",
                    title: "Iterate",
                    symbol: "wand.and.sparkles",
                    prompt: workflowSpine.iterationPrompt,
                    tint: AgentPalette.cyan
                ),
                QuickDelegateSuggestion(
                    id: "verify",
                    title: "Verify",
                    symbol: "checkmark.shield.fill",
                    prompt: "Verify \(workflowSpine.changedDetail), refresh proof, and report any remaining blocker.",
                    tint: AgentPalette.lilac
                )
            ]
        }
        return [
            QuickDelegateSuggestion(
                id: "inspect",
                title: "Inspect",
                symbol: "doc.text.magnifyingglass",
                prompt: "Inspect the workspace and tell me the important files, recent changes, and best next step.",
                tint: AgentPalette.cyan
            ),
            QuickDelegateSuggestion(
                id: "plan",
                title: "Plan",
                symbol: "checklist",
                prompt: "Plan the next safe changes for this workspace. Keep it concise and list what you would edit first.",
                tint: AgentPalette.cyan
            ),
            QuickDelegateSuggestion(
                id: "search",
                title: "Search",
                symbol: "magnifyingglass",
                prompt: "Search the workspace for TODO, FIXME, error, and failing. Summarize anything worth acting on.",
                tint: AgentPalette.lilac
            )
        ]
    }

    var body: some View {
        HStack(spacing: 8) {
            ForEach(suggestions) { suggestion in
                Button {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    send(suggestion)
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: suggestion.symbol)
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(suggestion.tint)
                            .frame(width: 10)
                        Text(suggestion.title)
                            .font(.system(size: 9, weight: .bold, design: AgentPalette.interfaceFontDesign))
                            .foregroundStyle(AgentPalette.ink)
                            .lineLimit(1)
                            .minimumScaleFactor(0.9)
                    }
                    .padding(.horizontal, 6)
                    .frame(width: chipWidth(for: suggestion), height: AgentDesign.minimumTouchTarget)
                    .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .agentControlSurface(radius: 8, tint: suggestion.tint, selected: false)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(suggestion.title) workspace")
                .accessibilityIdentifier("quickAction-\(suggestion.id)")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func chipWidth(for suggestion: QuickDelegateSuggestion) -> CGFloat {
        switch suggestion.id {
        case "plan": 64
        case "continue": 82
        case "iterate": 76
        case "verify": 72
        case "search": 82
        default: 84
        }
    }
}

private struct ThreadWindowBanner: View {
    let hiddenCount: Int
    let showingFullThread: Bool
    let toggle: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: showingFullThread ? "text.alignleft" : "clock.arrow.circlepath")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(AgentPalette.cyan)
                .frame(width: 28, height: 28)
                .agentSurface(radius: 9, tint: AgentPalette.cyan.opacity(0.10))

            VStack(alignment: .leading, spacing: 1) {
                Text(showingFullThread ? "Loaded visible history" : "Earlier context retained")
                    .font(.system(size: 11, weight: .bold, design: AgentPalette.interfaceFontDesign))
                    .foregroundStyle(AgentPalette.ink)
                    .lineLimit(1)
                Text(showingFullThread ? "Collapse to keep this session instant" : "\(hiddenCount) older messages hidden · loads in pages")
                    .font(.system(size: 9, weight: .semibold, design: AgentPalette.interfaceFontDesign))
                    .foregroundStyle(AgentPalette.secondaryText)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            Button(action: toggle) {
                Text(showingFullThread ? "Collapse" : "Load older")
                    .font(.system(size: 10, weight: .bold, design: AgentPalette.interfaceFontDesign))
                    .foregroundStyle(AgentPalette.ink)
                    .padding(.horizontal, 10)
                    .frame(height: AgentDesign.minimumTouchTarget)
                    .agentGlass(radius: 10, interactive: true, tint: AgentPalette.cyan.opacity(0.10))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(showingFullThread ? "Collapse earlier messages" : "Load older messages")
        }
        .padding(10)
        .agentSurface(radius: 16, tint: AgentPalette.cyan.opacity(0.04))
    }
}

private struct CodexChatTerminalCard: View {
    let isPaired: Bool
    let openSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                HStack(spacing: 4) {
                    Circle().fill(AgentPalette.rose).frame(width: 7, height: 7)
                    Circle().fill(AgentPalette.lilac).frame(width: 7, height: 7)
                    Circle().fill(AgentPalette.green).frame(width: 7, height: 7)
                }
                Text("codex simulated terminal")
                    .font(.system(size: 10, weight: .black, design: .monospaced))
                    .foregroundStyle(AgentPalette.terminalOutput)
                Spacer(minLength: 0)
                Text(isPaired ? "SIMULATED" : "SETUP")
                    .font(.system(size: 9, weight: .black, design: .monospaced))
                    .foregroundStyle(isPaired ? AgentPalette.green : AgentPalette.cyan)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("$ codex login --device-auth")
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundStyle(AgentPalette.terminalText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
                Text(isPaired ? "Simulated CLI flow reviewed. Real model calls still need API setup." : "Open Settings for the Start / Safari / Copy Code / Finish flow.")
                    .font(.system(size: 10, weight: .semibold, design: AgentPalette.interfaceFontDesign))
                    .foregroundStyle(AgentPalette.terminalOutput)
                    .lineLimit(2)
            }

            Button(action: openSettings) {
                Label(isPaired ? "Review Simulated Flow" : "Open Codex Terminal", systemImage: "terminal.fill")
                    .font(.system(size: 10, weight: .black, design: AgentPalette.interfaceFontDesign))
                    .foregroundStyle(AgentPalette.terminalText)
                    .frame(maxWidth: .infinity)
                    .frame(height: AgentDesign.minimumTouchTarget)
                    .agentControlSurface(radius: 11, tint: AgentPalette.indigo.opacity(0.16), selected: true)
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .background(
            LinearGradient(
                colors: [AgentPalette.terminalBackground.opacity(0.96), AgentPalette.codeBackground.opacity(0.98)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(AgentPalette.terminalSelection.opacity(0.60), lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("codexChatTerminalCard")
    }
}

private struct ChatHeaderView: View {
    let runtime: AgentRuntime
    let project: Project
    let projects: [Project]
    let scopedProject: Project?
    let conversation: Conversation
    @Bindable var settings: AgentSettings
    let artifacts: [WorkspaceArtifact]
    let durableSnapshot: ChatDurableRunSnapshot
    let workflowSpine: ProjectWorkflowSpine?
    let ownsActiveRunState: Bool
    let hasForeignActiveRun: Bool
    let foreignActiveTitle: String
    let newChat: () -> Void
    let changeScope: (Project?) -> Void
    let openWorkspaceSurface: (AppTab) -> Void
    let openArtifact: (WorkspaceArtifact) -> Void
    let openChatDrawer: () -> Void

    private var chatChromeTint: Color { AgentPalette.primaryAccent }

    private var sessionTitle: String {
        let trimmed = conversation.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "NovaForge" }
        if trimmed.localizedCaseInsensitiveCompare("NovaForge Session") == .orderedSame { return "NovaForge" }
        if trimmed.localizedCaseInsensitiveCompare(LaunchConversationSelection.safeStartTitle) == .orderedSame { return "NovaForge" }
        return trimmed
    }

    private var projectTitle: String {
        guard let scopedProject else { return "General workspace" }
        let trimmed = scopedProject.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? ProjectBootstrap.defaultProjectName : trimmed
    }

    private var scopeSymbol: String {
        scopedProject == nil ? "folder.fill" : "shippingbox.fill"
    }

    private var scopeModeLabel: String {
        scopedProject == nil ? "General Chat" : "Project Chat"
    }

    private var scopeModeTint: Color {
        scopedProject == nil ? AgentPalette.secondaryText : AgentPalette.cyan
    }

    private var sortedProjects: [Project] {
        projects.sorted { lhs, rhs in
            if lhs.id == scopedProject?.id { return true }
            if rhs.id == scopedProject?.id { return false }
            if lhs.lastActivityAt != rhs.lastActivityAt { return lhs.lastActivityAt > rhs.lastActivityAt }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    private var statusText: String {
        if hasForeignActiveRun { return "Elsewhere" }
        guard ownsActiveRunState else { return "Ready" }
        if runtime.queuedPromptCount > 0 { return "\(runtime.queuedPromptCount) queued" }
        if runtime.pendingTool != nil { return "Approval" }
        if runtime.isWorking { return "Working" }
        if runtime.lastError != nil { return "Failed" }
        return "Ready"
    }

    var body: some View {
        let _ = AgentPerformance.bodyEvaluation("Chat Header Body")
        VStack(alignment: .leading, spacing: 8) {
            headerRow

            ChatMemoryStrip(
                runtime: runtime,
                project: project,
                scopedProject: scopedProject,
                conversation: conversation,
                settings: settings,
                artifacts: artifacts,
                durableSnapshot: durableSnapshot,
                workflowSpine: workflowSpine,
                ownsActiveRunState: ownsActiveRunState,
                hasForeignActiveRun: hasForeignActiveRun,
                foreignActiveTitle: foreignActiveTitle,
                openWorkspaceSurface: openWorkspaceSurface,
                openArtifact: openArtifact
            )
        }
        .padding(8)
        .agentSurface(radius: 18, tint: chatChromeTint.opacity(0.04))
    }

    private var headerRow: some View {
        HStack(spacing: 10) {
            Button(action: openChatDrawer) {
                Image(systemName: "bubble.left.and.bubble.right")
                    .font(.system(size: 16, weight: .bold))
                    .frame(width: AgentDesign.controlHeight, height: AgentDesign.controlHeight)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open chats")
            .agentControlSurface(radius: AgentDesign.controlRadius, tint: chatChromeTint, selected: true)
            .minimumTapTarget()

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(sessionTitle)
                        .font(.system(size: 16, weight: .bold, design: AgentPalette.interfaceFontDesign))
                        .foregroundStyle(AgentPalette.ink)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .accessibilityIdentifier("currentChatTitle")

                    StatusDot(text: statusText, symbol: statusSymbol, tint: statusTint)
                }

                HStack(spacing: 6) {
                    Text(scopeModeLabel)
                        .font(.system(size: 8.5, weight: .black, design: AgentPalette.interfaceFontDesign))
                        .foregroundStyle(scopeModeTint)
                        .textCase(.uppercase)
                        .lineLimit(1)
                        .padding(.horizontal, 7)
                        .frame(height: 20)
                        .agentControlSurface(radius: 8, tint: scopeModeTint.opacity(0.10), selected: scopedProject != nil)
                        .accessibilityIdentifier("chatScopeModePill")

                    Menu {
                        Button {
                            changeScope(nil)
                        } label: {
                            Label("General workspace", systemImage: scopedProject == nil ? "checkmark.circle.fill" : "folder.fill")
                        }

                        Section("Projects") {
                            ForEach(sortedProjects.prefix(12), id: \.id) { candidate in
                                Button {
                                    changeScope(candidate)
                                } label: {
                                    Label(candidate.name, systemImage: scopedProject?.id == candidate.id ? "checkmark.circle.fill" : "shippingbox.fill")
                                }
                            }
                        }
                    } label: {
                        Label(projectTitle, systemImage: scopeSymbol)
                            .font(.system(size: 10, weight: .bold, design: AgentPalette.interfaceFontDesign))
                            .foregroundStyle(scopedProject == nil ? AgentPalette.secondaryText : AgentPalette.cyan)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("chatProjectScopeMenu")

                    Text("•")
                        .foregroundStyle(AgentPalette.quaternaryText)

                    Label(settings.provider.shortName, systemImage: settings.provider.symbol)
                        .font(.system(size: 10, weight: .bold, design: AgentPalette.interfaceFontDesign))
                        .foregroundStyle(settings.provider.tint)
                        .lineLimit(1)

                    if conversation.messageCount > 0 {
                        Text("•")
                            .foregroundStyle(AgentPalette.quaternaryText)

                        Text(messageCountText)
                            .font(.system(size: 10, weight: .semibold, design: AgentPalette.interfaceFontDesign))
                            .foregroundStyle(AgentPalette.secondaryText)
                            .lineLimit(1)
                    }

                    if hasForeignActiveRun {
                        Text("•")
                            .foregroundStyle(AgentPalette.quaternaryText)

                        Text("Running in \(foreignActiveTitle)")
                            .font(.system(size: 10, weight: .bold, design: AgentPalette.interfaceFontDesign))
                            .foregroundStyle(AgentPalette.cyan)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .accessibilityIdentifier("chatActiveElsewhereHeader")
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button(action: newChat) {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 16, weight: .bold))
                    .frame(width: AgentDesign.controlHeight, height: AgentDesign.controlHeight)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("New chat")
            .agentControlSurface(radius: AgentDesign.controlRadius, tint: AgentPalette.lilac, selected: true)
            .minimumTapTarget()
        }
    }

    private var messageCountText: String {
        let count = conversation.messageCount
        return "\(count) \(count == 1 ? "message" : "messages")"
    }

    private var modelSummary: String {
        let short = LocalModelCatalog.variant(for: settings.modelID)?.shortName ?? settings.modelID
        if short.count <= 22 { return short }
        return String(short.prefix(19)) + "…"
    }

    private var statusTint: Color {
        if hasForeignActiveRun { return AgentPalette.cyan }
        guard ownsActiveRunState else { return AgentPalette.accent }
        if runtime.pendingTool != nil { return AgentPalette.cyan }
        if runtime.lastError != nil { return AgentPalette.rose }
        if runtime.isWorking { return chatChromeTint }
        return AgentPalette.accent
    }

    private var statusSymbol: String {
        if hasForeignActiveRun { return "arrow.up.right.circle.fill" }
        guard ownsActiveRunState else { return "circle.fill" }
        return runtime.isWorking ? "waveform" : "circle.fill"
    }

}

private enum ChatMemoryChipTone: Equatable {
    case project
    case run
    case approval
    case file
    case artifact
    case proof
    case resume
    case model
    case warning

    var tint: Color {
        switch self {
        case .project: AgentPalette.cyan
        case .run: AgentPalette.primaryAccent
        case .approval: AgentPalette.cyan
        case .file: AgentPalette.indigo
        case .artifact: AgentPalette.green
        case .proof: AgentPalette.lilac
        case .resume: AgentPalette.blue
        case .model: AgentPalette.cyan
        case .warning: AgentPalette.rose
        }
    }
}

private enum ChatMemoryChipDestination: Equatable {
    case tab(AppTab)
    case artifact(String)
    case none
}

private struct ChatMemoryChip: Identifiable, Equatable {
    let id: String
    let title: String
    let detail: String
    let symbol: String
    let tone: ChatMemoryChipTone
    let destination: ChatMemoryChipDestination
    var isProminent = false
}

private struct ChatMemoryStrip: View {
    let runtime: AgentRuntime
    let project: Project
    let scopedProject: Project?
    let conversation: Conversation
    let settings: AgentSettings
    let artifacts: [WorkspaceArtifact]
    let durableSnapshot: ChatDurableRunSnapshot
    let workflowSpine: ProjectWorkflowSpine?
    let ownsActiveRunState: Bool
    let hasForeignActiveRun: Bool
    let foreignActiveTitle: String
    let openWorkspaceSurface: (AppTab) -> Void
    let openArtifact: (WorkspaceArtifact) -> Void

    private var chips: [ChatMemoryChip] {
        var result: [ChatMemoryChip] = [projectChip]

        if let runChip {
            result.append(runChip)
        }
        if let resumeChip {
            result.append(resumeChip)
        }
        if let fileChip {
            result.append(fileChip)
        }
        if let artifactChip {
            result.append(artifactChip)
        }
        if let proofChip {
            result.append(proofChip)
        }
        if let modelChip {
            result.append(modelChip)
        }
        if result.count == 1, let workflowSpine {
            result.append(ChatMemoryChip(
                id: "next",
                title: workflowSpine.nextActionTitle,
                detail: workflowSpine.nextActionDetail,
                symbol: "arrow.triangle.branch",
                tone: .run,
                destination: .tab(.project)
            ))
        }
        return result
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 7) {
                ForEach(chips) { chip in
                    ChatMemoryChipButton(chip: chip) {
                        activate(chip)
                    }
                }
            }
            .padding(.vertical, 1)
        }
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chatContextMemoryStrip")
    }

    private var projectChip: ChatMemoryChip {
        let scopedName = scopedProject?.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = scopedProject == nil ? "General" : "Project"
        let detail = scopedProject == nil
            ? "Default workspace"
            : (scopedName?.isEmpty == false ? scopedName! : project.name)
        return ChatMemoryChip(
            id: "project",
            title: title,
            detail: detail,
            symbol: scopedProject == nil ? "folder.fill" : "shippingbox.fill",
            tone: .project,
            destination: .tab(.project),
            isProminent: scopedProject != nil
        )
    }

    private var runChip: ChatMemoryChip? {
        if hasForeignActiveRun {
            return ChatMemoryChip(
                id: "foreign-run",
                title: "Running",
                detail: foreignActiveTitle,
                symbol: "arrow.up.right.circle.fill",
                tone: .run,
                destination: .none,
                isProminent: true
            )
        }
        guard ownsActiveRunState else { return nil }
        if let pending = runtime.pendingTool {
            return ChatMemoryChip(
                id: "pending-runtime",
                title: "Approval",
                detail: pendingDetail(for: pending),
                symbol: "checkmark.shield.fill",
                tone: .approval,
                destination: .tab(.runs),
                isProminent: true
            )
        }
        if runtime.isWorking {
            return ChatMemoryChip(
                id: "active-run",
                title: "Active Run",
                detail: runtime.activityTitle,
                symbol: "waveform",
                tone: .run,
                destination: .tab(.runs),
                isProminent: true
            )
        }
        if runtime.wasInterrupted || runtime.lastError != nil {
            return ChatMemoryChip(
                id: "recover-run",
                title: runtime.wasInterrupted ? "Paused" : "Failed",
                detail: runtime.lastError ?? "Continue from saved progress",
                symbol: runtime.wasInterrupted ? "pause.circle.fill" : "exclamationmark.triangle.fill",
                tone: runtime.wasInterrupted ? .resume : .warning,
                destination: .tab(.runs),
                isProminent: true
            )
        }
        if runtime.queuedPromptCount > 0 {
            return ChatMemoryChip(
                id: "queued",
                title: "Queued",
                detail: "\(runtime.queuedPromptCount) follow-up\(runtime.queuedPromptCount == 1 ? "" : "s")",
                symbol: "tray.full.fill",
                tone: .run,
                destination: .tab(.runs)
            )
        }
        if durableSnapshot.pendingApprovalCount > 0 {
            return ChatMemoryChip(
                id: "pending-durable",
                title: "Approval",
                detail: "\(durableSnapshot.pendingApprovalCount) waiting",
                symbol: "checkmark.shield.fill",
                tone: .approval,
                destination: .tab(.runs),
                isProminent: true
            )
        }
        return nil
    }

    private var resumeChip: ChatMemoryChip? {
        guard let projectOSRun = durableSnapshot.projectOSRun, projectOSRun.hasResumeCue else { return nil }
        return ChatMemoryChip(
            id: "projectos-\(projectOSRun.id.uuidString)",
            title: projectOSRun.displayTitle,
            detail: projectOSRun.displayDetail,
            symbol: "arrow.triangle.2.circlepath",
            tone: .resume,
            destination: .tab(.project),
            isProminent: true
        )
    }

    private var fileChip: ChatMemoryChip? {
        if let change = durableSnapshot.fileChanges.first {
            return ChatMemoryChip(
                id: "file-\(change.id.uuidString)",
                title: change.displayAction,
                detail: change.displayPath,
                symbol: "doc.text.fill",
                tone: .file,
                destination: .tab(.files)
            )
        }
        if let changedPath = workflowSpine?.latestChangedPath {
            return ChatMemoryChip(
                id: "file-\(changedPath)",
                title: workflowSpine?.changedTitle ?? "Changed",
                detail: shortPath(changedPath),
                symbol: "doc.text.fill",
                tone: .file,
                destination: .tab(.files)
            )
        }
        return nil
    }

    private var artifactChip: ChatMemoryChip? {
        guard let artifact = artifacts.first else { return nil }
        return ChatMemoryChip(
            id: "artifact-\(artifact.path)",
            title: artifact.isSwiftGameArtifact || artifact.isPlayableWebArtifact ? "Playable" : "Artifact",
            detail: artifact.title,
            symbol: artifact.handoffSymbol,
            tone: .artifact,
            destination: .artifact(artifact.path),
            isProminent: true
        )
    }

    private var proofChip: ChatMemoryChip? {
        if let proof = durableSnapshot.latestProof,
           !proof.title.localizedCaseInsensitiveContains("Project created") {
            return ChatMemoryChip(
                id: "proof-\(proof.id)",
                title: durableSnapshot.proofFreshness.isEmpty ? "Proof" : durableSnapshot.proofFreshness,
                detail: proof.title,
                symbol: proof.symbolName,
                tone: proof.severity == .failure ? .warning : .proof,
                destination: proof.sourcePath.map { .artifact($0) } ?? .tab(.runs)
            )
        }
        if let terminal = durableSnapshot.latestTerminalProof {
            return ChatMemoryChip(
                id: "terminal-\(terminal.id.uuidString)",
                title: "Terminal proof",
                detail: shortCommand(terminal.command),
                symbol: "terminal.fill",
                tone: terminal.status == .failed ? .warning : .proof,
                destination: .tab(.runs)
            )
        }
        return nil
    }

    private var modelChip: ChatMemoryChip? {
        guard settings.provider == .local, !runtime.localModels.isDownloaded else { return nil }
        return ChatMemoryChip(
            id: "model",
            title: "Model setup",
            detail: "Download needed",
            symbol: "arrow.down.circle.fill",
            tone: .model,
            destination: .tab(.settings),
            isProminent: true
        )
    }

    private func activate(_ chip: ChatMemoryChip) {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        switch chip.destination {
        case .tab(let tab):
            openWorkspaceSurface(tab)
        case .artifact(let path):
            openArtifact(WorkspaceArtifact(path: path))
        case .none:
            break
        }
    }

    private func pendingDetail(for request: ToolRequest) -> String {
        for key in ["path", "from", "to", "command", "query", "name"] {
            guard let value = request.arguments[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty else { continue }
            return key == "path" ? shortPath(value) : shorten(value, limit: 44)
        }
        return plainToolName(request.name)
    }

    private func shortPath(_ path: String) -> String {
        let name = URL(fileURLWithPath: path).lastPathComponent
        return name.isEmpty ? shorten(path, limit: 44) : name
    }

    private func shortCommand(_ command: String) -> String {
        shorten(command.replacingOccurrences(of: "\n", with: " "), limit: 48)
    }

    private func shorten(_ text: String, limit: Int) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > limit else { return trimmed }
        return String(trimmed.prefix(max(1, limit - 3))) + "..."
    }
}

private struct ChatMemoryChipButton: View {
    let chip: ChatMemoryChip
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: chip.symbol)
                    .font(.system(size: 10, weight: .black))
                    .foregroundStyle(chip.tone.tint)
                    .frame(width: 22, height: 22)
                    .agentControlSurface(radius: 8, tint: chip.tone.tint.opacity(0.12), selected: chip.isProminent)

                VStack(alignment: .leading, spacing: 1) {
                    Text(chip.title)
                        .font(.system(size: 9, weight: .black, design: AgentPalette.interfaceFontDesign))
                        .foregroundStyle(chip.tone.tint)
                        .textCase(.uppercase)
                        .lineLimit(1)
                    Text(chip.detail)
                        .font(.system(size: 10.5, weight: .bold, design: AgentPalette.interfaceFontDesign))
                        .foregroundStyle(AgentPalette.ink)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .minimumScaleFactor(0.78)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if chip.destination != .none {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .black))
                        .foregroundStyle(AgentPalette.tertiaryText)
                }
            }
            .padding(.leading, 7)
            .padding(.trailing, 8)
            .frame(width: chip.isProminent ? 164 : 142, height: 42)
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .agentControlSurface(radius: 14, tint: chip.tone.tint.opacity(chip.isProminent ? 0.13 : 0.08), selected: chip.isProminent)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(chip.title): \(chip.detail)")
        .accessibilityIdentifier("chatContextChip-\(chip.id)")
    }
}

private struct ComposerMenuButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.95 : 1.0)
            .animation(.spring(response: 0.2, dampingFraction: 0.65), value: configuration.isPressed)
    }
}

private struct ComposerModelMenu: View {
    @Environment(\.modelContext) private var modelContext
    @Bindable var settings: AgentSettings

    @State private var selectionError: String?

    var body: some View {
        Menu {
            Section("Provider") {
                ForEach(AIProvider.allCases) { provider in
                    Button {
                        selectProvider(provider)
                    } label: {
                        Label(
                            provider.displayName,
                            systemImage: settings.provider == provider ? "checkmark.circle.fill" : provider.symbol
                        )
                    }
                }
            }

            Section("\(settings.provider.displayName) Models") {
                ForEach(modelChoices, id: \.self) { model in
                    Button {
                        selectModel(model)
                    } label: {
                        Label(
                            refinedModelTitle(model),
                            systemImage: settings.modelID == model ? "checkmark.circle.fill" : modelMenuSymbol(for: model)
                        )
                    }
                }
            }

            if let selectionError {
                Section {
                    Text(selectionError)
                }
            }
        } label: {
            menuLabel
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Choose model, \(settings.provider.displayName), \(settings.modelID)")
                .accessibilityIdentifier("composerModelNativeMenu")
        }
        .menuStyle(.button)
        .buttonStyle(ComposerMenuButtonStyle())
        .accessibilityLabel("Choose model, \(settings.provider.displayName), \(settings.modelID)")
        .accessibilityIdentifier("composerModelNativeMenu")
    }

    private var menuLabel: some View {
        HStack(spacing: 5) {
            Image(systemName: settings.provider.symbol)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(
                    LinearGradient(
                        colors: [settings.provider.tint, settings.provider.tint.opacity(0.7)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: 20, height: 20)
                .background {
                    Circle()
                        .fill(settings.provider.tint.opacity(0.09))
                }

            Text(labelText)
                .font(.system(size: 12, weight: .semibold, design: AgentPalette.interfaceFontDesign))
                .foregroundStyle(AgentPalette.ink)
                .lineLimit(1)
                .truncationMode(.tail)
                .minimumScaleFactor(0.76)
                .layoutPriority(1)

            Image(systemName: "chevron.down")
                .font(.system(size: 7, weight: .bold))
                .foregroundStyle(settings.provider.tint.opacity(0.70))
        }
        .padding(.leading, 8)
        .padding(.trailing, 8)
        .frame(height: 34)
        .frame(minWidth: 124, maxWidth: 168, alignment: .leading)
        .background {
            ZStack {
                Capsule(style: .continuous)
                    .fill(settings.provider.tint.opacity(0.055))

                Capsule(style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [AgentPalette.glassStroke.opacity(0.50), .clear],
                            startPoint: .top,
                            endPoint: .center
                        )
                    )
                    .opacity(0.24)
            }
        }
        .clipShape(Capsule(style: .continuous))
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(AgentPalette.glassStroke.opacity(0.54), lineWidth: 0.55)
        )
        .shadow(color: settings.provider.tint.opacity(0.025), radius: 2, x: 0, y: 1)
    }

    private var labelText: String {
        compactComposerModelLabel
    }

    private var compactComposerModelLabel: String {
        let modelName = compactComposerModelName
        let providerName = settings.provider.shortName
        if modelName.range(of: providerName, options: [.caseInsensitive, .diacriticInsensitive]) != nil {
            return modelName
        }
        return truncatedComposerModelName("\(providerName) \(modelName)")
    }

    private var compactComposerModelName: String {
        let refinedName = refinedModelTitle(settings.modelID)
        let displayName = refinedName.split(separator: "/", maxSplits: 1).last.map(String.init) ?? refinedName
        let name = displayName
            .replacingOccurrences(of: "VibeThinker", with: "")
            .replacingOccurrences(of: "Instruct", with: "")
            .replacingOccurrences(of: "Model", with: "")
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .split(separator: " ")
            .map(compactModelToken)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { return settings.provider.shortName }
        return truncatedComposerModelName(name)
    }

    private func truncatedComposerModelName(_ name: String) -> String {
        guard name.count > 18 else { return name }
        var fitted = ""
        for token in name.split(separator: " ") {
            let candidate = fitted.isEmpty ? String(token) : "\(fitted) \(token)"
            guard candidate.count + 3 <= 18 else { break }
            fitted = candidate
        }
        if !fitted.isEmpty { return "\(fitted)..." }
        return String(name.prefix(15)).trimmingCharacters(in: .whitespacesAndNewlines) + "..."
    }

    private func compactModelToken(_ token: Substring) -> String {
        let raw = String(token)
        let lower = raw.lowercased()
        switch lower {
        case "gpt", "glm", "ai", "api":
            return lower.uppercased()
        case "codex":
            return "Codex"
        case "deepseek":
            return "DeepSeek"
        case "gemini":
            return "Gemini"
        case "grok":
            return "Grok"
        case "kimi":
            return "Kimi"
        case "minimax":
            return "MiniMax"
        case "qwen3":
            return "Qwen3"
        case "ios":
            return "iOS"
        default:
            return raw.prefix(1).uppercased() + String(raw.dropFirst())
        }
    }

    private var modelChoices: [String] {
        uniqueModels(settings.provider.modelOptions + [settings.modelID])
    }

    private func refinedModelTitle(_ model: String) -> String {
        LocalModelCatalog.variant(for: model)?.shortName ?? model
    }

    private func modelMenuSymbol(for model: String) -> String {
        if LocalModelCatalog.variant(for: model) != nil { return "iphone.gen3" }
        if model.localizedCaseInsensitiveContains("codex") { return "terminal.fill" }
        if model.localizedCaseInsensitiveContains("gpt") { return "sparkles" }
        return "cube.transparent"
    }

    private func selectProvider(_ provider: AIProvider) {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        guard settings.provider != provider else { return }
        guard persistSettingsChange(failureTitle: "Provider Not Saved", mutate: { settings in
            settings.switchProvider(to: provider)
        }) else { return }
        selectionError = nil
    }

    private func selectModel(_ model: String) {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        if persistSettingsChange(failureTitle: "Model Not Saved", mutate: { settings in
            settings.modelID = trimmed
        }) {
            selectionError = nil
        }
    }

    @discardableResult
    private func persistSettingsChange(failureTitle: String, mutate: (AgentSettings) -> Void) -> Bool {
        do {
            try AgentSettingsPersistence.persist(
                settings: settings,
                mutate: mutate,
                save: { try modelContext.save() }
            )
            return true
        } catch {
            selectionError = "\(failureTitle): \(error.localizedDescription). Your previous provider and model are still active."
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            return false
        }
    }

    private func uniqueModels(_ models: [String]) -> [String] {
        var seen = Set<String>()
        return models.compactMap { model in
            let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { return nil }
            return trimmed
        }
    }
}

private struct ComposerSendButton: View {
    let title: String?
    let isQueueing: Bool
    let isEnabled: Bool
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                sendCapsule
                    .frame(width: title == nil ? 34 : nil, height: title == nil ? 34 : nil)

                ViewThatFits(in: .horizontal) {
                    sendLabel(showTitle: title != nil)
                    sendLabel(showTitle: false)
                }
                .foregroundStyle(isEnabled ? enabledForeground : AgentPalette.secondaryText.opacity(0.72))
                .padding(.horizontal, title == nil ? 0 : 10)
            }
            .frame(minWidth: title == nil ? 46 : 82, minHeight: 46)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func sendLabel(showTitle: Bool) -> some View {
        HStack(spacing: showTitle ? 6 : 0) {
            Image(systemName: isQueueing ? "plus.message.fill" : "arrow.up")
                .font(.system(size: 14, weight: .black))

            if showTitle, let title {
                Text(title)
                    .font(.system(size: 11, weight: .black, design: AgentPalette.interfaceFontDesign))
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
            }
        }
    }

    private var enabledForeground: Color {
        AgentPalette.isLight ? AgentPalette.pearl : AgentPalette.ink
    }

    private var sendCapsule: some View {
        Capsule()
            .fill(
                LinearGradient(
                    colors: isEnabled ? [tint.opacity(0.98), AgentPalette.lilac.opacity(0.90)] : [
                        AgentPalette.secondaryText.opacity(0.12),
                        AgentPalette.tertiaryText.opacity(0.08)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
    }
}

private struct StatusDot: View {
    let text: String
    let symbol: String
    let tint: Color

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: symbol)
                .font(.system(size: 7, weight: .bold))
            Text(text)
                .font(.system(size: 9, weight: .bold, design: AgentPalette.interfaceFontDesign))
                .lineLimit(1)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 8)
        .frame(height: 24)
        .agentControlSurface(radius: 8, tint: tint.opacity(0.10), selected: true)
    }
}

private struct ChatContextBar: View {
    let runtime: AgentRuntime
    let settings: AgentSettings
    let artifacts: [WorkspaceArtifact]
    let durableSnapshot: ChatDurableRunSnapshot
    let workflowSpine: ProjectWorkflowSpine?
    let openArtifact: (WorkspaceArtifact) -> Void
    let retry: () -> Void
    let continueRun: () -> Void
    let stop: () -> Void
    let openWorkspaceSurface: (AppTab) -> Void
    let clear: () -> Void
    @Binding var expanded: Bool

    private var primaryArtifact: WorkspaceArtifact? { artifacts.first }
    private var hasCompletedRunEvidence: Bool {
        runtime.lastRunDuration != nil ||
            runtime.runState == .completed ||
            runtime.hasSuccessfulTraceEvent ||
            primaryArtifact != nil ||
            durableSnapshot.hasCompletionEvidence
    }

    private var visibleTraceEvents: [AgentTraceEvent] {
        ChatDurableRunSnapshot.mergedTraceEvents(
            runtime: runtime.traceEvents,
            durable: durableSnapshot.traceEvents
        )
    }

    private var lastRunDuration: TimeInterval? {
        runtime.lastRunDuration ?? durableSnapshot.lastRunDuration
    }

    var body: some View {
        let _ = AgentPerformance.bodyEvaluation("Chat Context Bar Body")
        VStack(spacing: 10) {
            Button {
                toggleExpanded()
            } label: {
                HStack(spacing: 10) {
                    contextIcon

                    VStack(alignment: .leading, spacing: 3) {
                        Text(title)
                            .font(.system(size: 12, weight: .heavy, design: AgentPalette.interfaceFontDesign))
                            .foregroundStyle(AgentPalette.ink)
                            .lineLimit(1)
                        Text(subtitle)
                            .font(.system(size: 10, weight: .bold, design: AgentPalette.interfaceFontDesign))
                            .foregroundStyle(AgentPalette.secondaryText)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    statusPill

                    Image(systemName: "chevron.up")
                        .font(.system(size: 13, weight: .black))
                        .foregroundStyle(tint)
                        .rotationEffect(.degrees(expanded ? 180 : 0))
                        .frame(width: AgentDesign.minimumTouchTarget, height: AgentDesign.minimumTouchTarget)
                        .agentControlSurface(radius: 15, tint: tint.opacity(0.14), selected: true)
                }
                .padding(.leading, 2)
                .frame(minHeight: AgentDesign.minimumTouchTarget)
                .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(expanded ? "Hide progress details" : "Show progress details")
            .accessibilityIdentifier("runProgressToggle")

            if expanded {
                ScrollView(.vertical, showsIndicators: false) {
                    AgentProgressDrawer(
                        runtime: runtime,
                        tint: tint,
                        artifacts: artifacts,
                        durableSnapshot: durableSnapshot,
                        workflowSpine: workflowSpine,
                        openArtifact: openArtifact,
                        retry: retry,
                        continueRun: continueRun,
                        stop: stop,
                        openWorkspaceSurface: openWorkspaceSurface,
                        clear: clear
                    )
                    .padding(.bottom, 2)
                }
                .frame(maxHeight: 430)
                .scrollBounceBehavior(.basedOnSize)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity)
        .runContextSurface(usesPolishedSurface: AgentPerformance.prefersReducedVisualEffects && runtime.isWorking && !expanded, tint: tint)
    }

    @ViewBuilder
    private var contextIcon: some View {
        if runtime.isWorking {
            ProgressStatusIcon(tint: tint)
        } else {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .black))
                .foregroundStyle(tint)
                .frame(width: 34, height: 34)
                .agentControlSurface(radius: 12, tint: tint.opacity(0.14), selected: true)
        }
    }

    private var statusPill: some View {
        Text(statusPillText)
            .font(.system(size: 9, weight: .black, design: AgentPalette.interfaceFontDesign))
            .foregroundStyle(tint)
            .textCase(.uppercase)
            .padding(.horizontal, 8)
            .frame(height: 24)
            .agentControlSurface(radius: 9, tint: tint.opacity(0.12), selected: true)
    }

    private var title: String {
        if runtime.lastError != nil { return "Run failed" }
        if runtime.wasInterrupted { return "Run paused" }
        if let pending = runtime.pendingTool { return "Approval needed: \(plainToolName(pending.name))" }
        if runtime.queuedPromptCount > 0 { return "\(runtime.queuedPromptCount) follow-up queued" }
        if runtime.isWorking { return runtime.activityTitle }
        if hasCompletedRunEvidence { return "Run complete" }
        if primaryArtifact != nil { return "Latest artifact" }
        return "Ready"
    }

    private var subtitle: String {
        if runtime.lastError != nil { return "Retry or clear from the menu" }
        if runtime.wasInterrupted { return "Continue, retry, or inspect what changed" }
        if runtime.pendingTool != nil { return "Approve or reject before sending the next message." }
        if runtime.isWorking { return runtime.activityDetail }
        if hasCompletedRunEvidence || !visibleTraceEvents.isEmpty {
            if let workflowSpine {
                return "\(workflowSpine.nextActionTitle): \(workflowSpine.nextActionDetail)"
            }
            return completionSummary
        }
        if let artifact = primaryArtifact { return artifact.path }
        return "\(settings.provider.displayName) · \(settings.modelID)"
    }

    private var icon: String {
        if runtime.lastError != nil { return "exclamationmark.triangle.fill" }
        if runtime.wasInterrupted { return "pause.circle.fill" }
        if runtime.pendingTool != nil { return "checkmark.shield.fill" }
        if hasCompletedRunEvidence { return "checkmark.circle.fill" }
        if !artifacts.isEmpty { return "paperclip" }
        return "sparkles"
    }

    private var statusPillText: String {
        if runtime.lastError != nil { return "Failed" }
        if runtime.wasInterrupted { return "Paused" }
        if runtime.pendingTool != nil { return "Approve" }
        if runtime.isWorking { return "Live" }
        if hasCompletedRunEvidence { return "Done" }
        if !artifacts.isEmpty { return "New" }
        return "Ready"
    }

    private var tint: Color {
        if runtime.lastError != nil { return AgentPalette.rose }
        if runtime.wasInterrupted { return AgentPalette.cyan }
        if runtime.pendingTool != nil { return AgentPalette.cyan }
        if runtime.isWorking { return AgentPalette.primaryAccent }
        if hasCompletedRunEvidence { return AgentPalette.green }
        return AgentPalette.cyan
    }

    private var completionSummary: String {
        let stepCount = visibleTraceEvents.count
        let stepText = "\(stepCount) visible step\(stepCount == 1 ? "" : "s")"
        let artifactPrefix = primaryArtifact.map { "\($0.title) ready · " } ?? ""
        if let duration = lastRunDuration {
            return "\(artifactPrefix)\(stepText) · \(formatDuration(duration))"
        }
        return "\(artifactPrefix)\(stepText)"
    }

    private func toggleExpanded() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        withAnimation(.smooth(duration: 0.22)) {
            expanded.toggle()
        }
    }

    private func formatDuration(_ duration: TimeInterval) -> String {
        duration < 1 ? String(format: "%.0fms", duration * 1000) : String(format: "%.1fs", duration)
    }
}

private struct AgentProgressDrawer: View {
    let runtime: AgentRuntime
    let tint: Color
    let artifacts: [WorkspaceArtifact]
    let durableSnapshot: ChatDurableRunSnapshot
    let workflowSpine: ProjectWorkflowSpine?
    let openArtifact: (WorkspaceArtifact) -> Void
    let retry: () -> Void
    let continueRun: () -> Void
    let stop: () -> Void
    let openWorkspaceSurface: (AppTab) -> Void
    let clear: () -> Void

    private var visibleTraceEvents: [AgentTraceEvent] {
        ChatDurableRunSnapshot.mergedTraceEvents(
            runtime: runtime.traceEvents,
            durable: durableSnapshot.traceEvents
        )
    }

    private var secondaryArtifacts: [WorkspaceArtifact] {
        Array(artifacts.dropFirst())
    }

    private var completedSteps: Int {
        visibleTraceEvents.filter { $0.status == .success }.count
    }

    private var issueCount: Int {
        visibleTraceEvents.filter { $0.status == .failed || $0.status == .paused }.count
    }

    private var runDurationText: String {
        guard let duration = runtime.lastRunDuration ?? durableSnapshot.lastRunDuration else {
            if runtime.isWorking { return "Live" }
            if runtime.lastError != nil { return "Failed" }
            if runtime.pendingTool != nil { return "Pending" }
            if runtime.wasInterrupted { return "Paused" }
            if runtime.runState == .completed ||
                visibleTraceEvents.contains(where: { $0.status == .success }) ||
                durableSnapshot.hasCompletionEvidence {
                return "Done"
            }
            return "Ready"
        }
        return duration < 1 ? String(format: "%.0fms", duration * 1000) : String(format: "%.1fs", duration)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            runHeader

            if let pending = runtime.pendingTool {
                runSection(title: "Approval Queue", symbol: "checkmark.shield.fill", tint: AgentPalette.cyan) {
                    PendingApprovalInlineCard(request: pending)
                }
            }

            if runtime.activeToolName != nil {
                activeToolPanel
            }

            if !artifacts.isEmpty {
                runSection(title: artifacts[0].handoffTitle, symbol: artifacts[0].handoffSymbol, tint: AgentPalette.green) {
                    ArtifactHandoffCard(artifact: artifacts[0], openArtifact: openArtifact)
                }

                if !secondaryArtifacts.isEmpty {
                    runSection(title: "Also changed", symbol: "paperclip", tint: AgentPalette.cyan) {
                        artifactStrip(secondaryArtifacts)
                    }
                }
            }

            if !durableSnapshot.fileChanges.isEmpty {
                runSection(title: "Changed Files", symbol: "doc.text.fill", tint: AgentPalette.indigo) {
                    fileChangeStrip(durableSnapshot.fileChanges)
                }
            }

            if durableSnapshot.latestProof != nil || durableSnapshot.latestTerminalProof != nil || !durableSnapshot.reviewHeadline.isEmpty {
                runSection(title: "Proof", symbol: "checkmark.seal.fill", tint: AgentPalette.lilac) {
                    ProofContextCard(
                        durableSnapshot: durableSnapshot,
                        openArtifact: openArtifact,
                        openRuns: {
                            openWorkspaceSurface(.runs)
                        }
                    )
                }
            }

            if !visibleTraceEvents.isEmpty {
                runSection(title: "Progress", symbol: "timeline.selection", tint: tint) {
                    VStack(spacing: 0) {
                        ForEach(Array(visibleTraceEvents.enumerated()), id: \.element.id) { index, event in
                            AgentTraceRow(
                                event: event,
                                isFirst: index == 0,
                                isLast: index == visibleTraceEvents.count - 1
                            )
                        }
                    }
                    .padding(.vertical, 4)
                    .agentRowSurface(radius: 14, tint: tint.opacity(0.05))
                }
            }

            HStack(alignment: .top, spacing: 10) {
                runSection(title: "Workspace", symbol: "square.grid.2x2.fill", tint: AgentPalette.indigo) {
                    workspaceShortcuts
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)

                runSection(title: "Next", symbol: "arrow.triangle.branch", tint: AgentPalette.blue) {
                    nextActions
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .padding(.top, 2)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("runControlDrawer")
    }

    private var runHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Run Control")
                    .font(.system(size: 13, weight: .black, design: AgentPalette.interfaceFontDesign))
                    .foregroundStyle(AgentPalette.ink)
                Spacer(minLength: 0)
                Text(runtime.isWorking ? "IN PROGRESS" : issueCount > 0 ? "NEEDS REVIEW" : "FINISHED")
                    .font(.system(size: 8, weight: .black, design: AgentPalette.interfaceFontDesign))
                    .foregroundStyle(issueCount > 0 ? AgentPalette.rose : tint)
                    .padding(.horizontal, 8)
                    .frame(height: 22)
                    .agentControlSurface(radius: 8, tint: (issueCount > 0 ? AgentPalette.rose : tint).opacity(0.12), selected: true)
            }

            HStack(spacing: 8) {
                RunMetric(value: "\(visibleTraceEvents.count)", label: "Steps", symbol: "checklist", tint: tint, valueIdentifier: "runStepsMetric")
                RunMetric(value: "\(artifacts.count)", label: "Files", symbol: "paperclip", tint: AgentPalette.cyan, valueIdentifier: "runFilesMetric")
                RunMetric(value: runDurationText, label: "Time", symbol: "timer", tint: AgentPalette.lilac, valueIdentifier: "runTimeMetric")
            }
        }
        .padding(11)
        .background(
            LinearGradient(
                colors: [AgentPalette.surface, tint.opacity(0.10), AgentPalette.lilac.opacity(0.06)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
        )
        .agentSurface(radius: 16, tint: tint.opacity(0.08))
    }

    @ViewBuilder
    private func runSection<Content: View>(
        title: String,
        symbol: String,
        tint: Color,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            ProgressDrawerLabel(text: title, symbol: symbol, tint: tint)
            content()
        }
    }

    private var activeToolPanel: some View {
        HStack(alignment: .top, spacing: 10) {
            ZStack {
                Circle()
                    .fill(AgentPalette.cyan.opacity(0.16))
                    .frame(width: 34, height: 34)
                Image(systemName: "bolt.horizontal.circle.fill")
                    .font(.system(size: 15, weight: .heavy))
                    .foregroundStyle(AgentPalette.cyan)
            }

            VStack(alignment: .leading, spacing: 4) {
                ProgressDrawerLabel(text: "Running Tool", symbol: "wrench.and.screwdriver.fill", tint: AgentPalette.cyan)
                Text(runtime.activeToolName ?? "Tool")
                    .font(.system(size: 13, weight: .heavy, design: AgentPalette.interfaceFontDesign))
                    .foregroundStyle(AgentPalette.ink)
                    .lineLimit(1)
                if !runtime.activeToolDetail.isEmpty {
                    Text(runtime.activeToolDetail)
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(AgentPalette.secondaryText)
                        .lineLimit(3)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
            }

            Spacer(minLength: 0)

            Text("live")
                .font(.system(size: 9, weight: .heavy, design: AgentPalette.interfaceFontDesign))
                .foregroundStyle(AgentPalette.cyan)
                .padding(.horizontal, 7)
                .frame(height: 22)
                .agentControlSurface(radius: 8, tint: AgentPalette.cyan.opacity(0.12), selected: true)
        }
        .padding(11)
        .background(
            LinearGradient(
                colors: [AgentPalette.surface, AgentPalette.cyan.opacity(0.10), AgentPalette.cyan.opacity(0.05)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 15, style: .continuous)
        )
        .agentSurface(radius: 15, tint: AgentPalette.cyan.opacity(0.10))
    }

    private func artifactStrip(_ artifacts: [WorkspaceArtifact]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 7) {
                ForEach(artifacts.prefix(5)) { artifact in
                    Button {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        openArtifact(artifact)
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: artifact.isWebPage || artifact.isSwiftGameArtifact ? artifact.handoffSymbol : artifact.symbol)
                                .font(.system(size: 10, weight: .bold))
                            Text(artifact.title)
                                .font(.system(size: 10, weight: .bold, design: AgentPalette.interfaceFontDesign))
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        .foregroundStyle(AgentPalette.ink)
                        .padding(.horizontal, 9)
                        .frame(height: 40)
                        .frame(maxWidth: 172)
                        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .agentControlSurface(radius: 14, tint: AgentPalette.cyan.opacity(0.10), selected: true)
                    }
                    .buttonStyle(.plain)
                    .frame(minWidth: 128, minHeight: 44)
                    .contentShape(Rectangle())
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Preview artifact \(artifact.title)")
                    .accessibilityIdentifier("artifactSecondaryOpenButton")
                }
                if artifacts.count > 5 {
                    Text("+\(artifacts.count - 5)")
                        .font(.system(size: 10, weight: .black, design: AgentPalette.interfaceFontDesign))
                        .foregroundStyle(AgentPalette.cyan)
                        .frame(width: 34, height: 30)
                        .agentControlSurface(radius: 10, tint: AgentPalette.cyan.opacity(0.10), selected: true)
                }
            }
        }
    }

    private func fileChangeStrip(_ changes: [ChatFileChangeSnapshot]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 7) {
                ForEach(changes.prefix(5)) { change in
                    Button {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        openWorkspaceSurface(.files)
                    } label: {
                        HStack(spacing: 7) {
                            Image(systemName: "doc.text.fill")
                                .font(.system(size: 10, weight: .black))
                                .foregroundStyle(AgentPalette.indigo)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(change.displayAction)
                                    .font(.system(size: 8, weight: .black, design: AgentPalette.interfaceFontDesign))
                                    .foregroundStyle(AgentPalette.indigo)
                                    .textCase(.uppercase)
                                    .lineLimit(1)
                                Text(change.displayPath)
                                    .font(.system(size: 10, weight: .bold, design: AgentPalette.interfaceFontDesign))
                                    .foregroundStyle(AgentPalette.ink)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }
                        .padding(.horizontal, 9)
                        .frame(width: 154, height: 42, alignment: .leading)
                        .contentShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
                        .agentControlSurface(radius: 13, tint: AgentPalette.indigo.opacity(0.09), selected: false)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Open changed file \(change.displayPath)")
                    .accessibilityIdentifier("progressChangedFileButton")
                }
            }
        }
    }

    private var workspaceShortcuts: some View {
        VStack(spacing: 7) {
            ProgressActionButton(title: "Files", symbol: "folder.fill", tint: AgentPalette.cyan, identifier: "progressFilesButton") {
                openWorkspaceSurface(.files)
            }
            ProgressActionButton(title: "Runs", symbol: "list.bullet.rectangle.portrait.fill", tint: AgentPalette.cyan, identifier: "progressRunsButton") {
                openWorkspaceSurface(.runs)
            }
        }
    }

    private var nextActions: some View {
        VStack(spacing: 7) {
            if let workflowSpine {
                VStack(alignment: .leading, spacing: 2) {
                    Text(workflowSpine.nextActionTitle)
                        .font(.system(size: 8, weight: .black, design: AgentPalette.interfaceFontDesign))
                        .foregroundStyle(AgentPalette.tertiaryText)
                        .textCase(.uppercase)
                    Text(workflowSpine.iterationPrompt)
                        .font(.system(size: 9.5, weight: .bold, design: AgentPalette.interfaceFontDesign))
                        .foregroundStyle(AgentPalette.secondaryText)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .agentRowSurface(radius: 10, tint: AgentPalette.blue.opacity(0.08), selected: true)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(workflowSpine.nextActionTitle). \(workflowSpine.iterationPrompt)")
                .accessibilityIdentifier("progressProjectNextAction")
            }

            if runtime.isWorking {
                ProgressActionButton(title: "Pause", symbol: "pause.fill", tint: AgentPalette.rose, identifier: "progressPauseButton", action: stop)
            } else if runtime.pendingTool != nil {
                HStack(spacing: 5) {
                    Image(systemName: "checkmark.shield.fill")
                        .font(.system(size: 9, weight: .bold))
                    Text("Approve / Reject")
                        .font(.system(size: 10, weight: .bold, design: AgentPalette.interfaceFontDesign))
                }
                .foregroundStyle(AgentPalette.cyan)
                .frame(maxWidth: .infinity)
                .frame(height: AgentDesign.minimumTouchTarget)
                .agentControlSurface(radius: 10, tint: AgentPalette.cyan.opacity(0.10), selected: true)
            } else if runtime.wasInterrupted || runtime.lastError != nil {
                ProgressActionButton(title: "Continue", symbol: "play.fill", tint: AgentPalette.blue, identifier: "progressContinueButton", action: continueRun)
                ProgressActionButton(title: "Retry", symbol: "arrow.clockwise", tint: AgentPalette.cyan, identifier: "progressRetryButton", action: retry)
            } else {
                ProgressActionButton(title: "Clear", symbol: "checkmark", tint: AgentPalette.blue, identifier: "progressClearButton", action: clear)
            }

            if runtime.queuedPromptCount > 0 {
                HStack(spacing: 5) {
                    Image(systemName: "tray.full.fill")
                        .font(.system(size: 9, weight: .bold))
                    Text("\(runtime.queuedPromptCount) queued")
                        .font(.system(size: 10, weight: .bold, design: AgentPalette.interfaceFontDesign))
                }
                .foregroundStyle(AgentPalette.cyan)
                .frame(maxWidth: .infinity)
                .frame(height: AgentDesign.minimumTouchTarget)
                .agentControlSurface(radius: 10, tint: AgentPalette.cyan.opacity(0.10), selected: true)
            }
        }
    }
}

private struct PendingApprovalInlineCard: View {
    let request: ToolRequest

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: request.isMutating ? "pencil.and.outline" : "eye.fill")
                .font(.system(size: 14, weight: .black))
                .foregroundStyle(AgentPalette.cyan)
                .frame(width: 36, height: 36)
                .agentControlSurface(radius: 13, tint: AgentPalette.cyan.opacity(0.14), selected: true)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(plainToolName(request.name))
                        .font(.system(size: 12, weight: .black, design: AgentPalette.interfaceFontDesign))
                        .foregroundStyle(AgentPalette.ink)
                        .lineLimit(1)
                    Text(request.isMutating ? "changes files" : "read only")
                        .font(.system(size: 8.5, weight: .black, design: AgentPalette.interfaceFontDesign))
                        .foregroundStyle(request.isMutating ? AgentPalette.cyan : AgentPalette.green)
                        .textCase(.uppercase)
                        .padding(.horizontal, 7)
                        .frame(height: 20)
                        .agentControlSurface(
                            radius: 7,
                            tint: (request.isMutating ? AgentPalette.cyan : AgentPalette.green).opacity(0.10),
                            selected: true
                        )
                }

                Text(argumentSummary)
                    .font(.system(size: 10, weight: .semibold, design: AgentPalette.interfaceFontDesign))
                    .foregroundStyle(AgentPalette.secondaryText)
                    .lineLimit(2)
                    .truncationMode(.middle)

                Text("Open the approval sheet to approve or reject; the run is paused.")
                    .font(.system(size: 9, weight: .bold, design: AgentPalette.interfaceFontDesign))
                    .foregroundStyle(AgentPalette.tertiaryText)
                    .lineLimit(2)
            }

            Spacer(minLength: 0)
        }
        .padding(11)
        .background(
            LinearGradient(
                colors: [AgentPalette.surface, AgentPalette.cyan.opacity(0.10), AgentPalette.lilac.opacity(0.05)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
        )
        .agentRowSurface(radius: 16, tint: AgentPalette.cyan.opacity(0.08), selected: true)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("pendingApprovalInlineCard")
    }

    private var argumentSummary: String {
        for key in ["path", "from", "to", "query", "command"] {
            guard let value = request.arguments[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty else { continue }
            let oneLine = value.replacingOccurrences(of: "\n", with: " ")
            return oneLine.count > 96 ? String(oneLine.prefix(96)) + "..." : oneLine
        }
        return "\(request.arguments.count) argument\(request.arguments.count == 1 ? "" : "s") ready"
    }
}

private struct ProofContextCard: View {
    let durableSnapshot: ChatDurableRunSnapshot
    let openArtifact: (WorkspaceArtifact) -> Void
    let openRuns: () -> Void

    private var tint: Color {
        if durableSnapshot.latestProof?.severity == .failure ||
            durableSnapshot.latestTerminalProof?.status == .failed {
            return AgentPalette.rose
        }
        if durableSnapshot.proofFreshness.localizedCaseInsensitiveContains("stale") {
            return AgentPalette.rose
        }
        return AgentPalette.lilac
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: symbolName)
                    .font(.system(size: 14, weight: .black))
                    .foregroundStyle(tint)
                    .frame(width: 34, height: 34)
                    .agentControlSurface(radius: 12, tint: tint.opacity(0.14), selected: true)

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 12, weight: .black, design: AgentPalette.interfaceFontDesign))
                        .foregroundStyle(AgentPalette.ink)
                        .lineLimit(1)
                    Text(detail)
                        .font(.system(size: 9.5, weight: .semibold, design: AgentPalette.interfaceFontDesign))
                        .foregroundStyle(AgentPalette.secondaryText)
                        .lineLimit(2)
                        .truncationMode(.tail)
                }

                Spacer(minLength: 0)

                Text(durableSnapshot.proofFreshness.isEmpty ? "Proof" : durableSnapshot.proofFreshness)
                    .font(.system(size: 8, weight: .black, design: AgentPalette.interfaceFontDesign))
                    .foregroundStyle(tint)
                    .textCase(.uppercase)
                    .padding(.horizontal, 7)
                    .frame(height: 21)
                    .agentControlSurface(radius: 8, tint: tint.opacity(0.12), selected: true)
            }

            HStack(spacing: 7) {
                if let sourcePath = durableSnapshot.latestProof?.sourcePath {
                    ProgressActionButton(title: "Open Proof", symbol: "arrow.up.right.square.fill", tint: AgentPalette.lilac, identifier: "progressOpenProofButton") {
                        openArtifact(WorkspaceArtifact(path: sourcePath))
                    }
                }

                ProgressActionButton(title: "Runs", symbol: "list.bullet.rectangle.portrait.fill", tint: AgentPalette.lilac, identifier: "progressProofRunsButton", action: openRuns)
            }

            if !evidenceTrail.isEmpty {
                Text(evidenceTrail)
                    .font(.system(size: 9, weight: .bold, design: AgentPalette.interfaceFontDesign))
                    .foregroundStyle(AgentPalette.tertiaryText)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .padding(11)
        .agentRowSurface(radius: 16, tint: tint.opacity(0.08), selected: true)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("proofContextCard")
    }

    private var symbolName: String {
        durableSnapshot.latestProof?.symbolName ?? "checkmark.seal.fill"
    }

    private var title: String {
        if let proof = durableSnapshot.latestProof,
           !proof.title.localizedCaseInsensitiveContains("Project created") {
            return proof.title
        }
        if durableSnapshot.latestTerminalProof != nil {
            return "Terminal proof captured"
        }
        return durableSnapshot.reviewHeadline.isEmpty ? "Proof status" : durableSnapshot.reviewHeadline
    }

    private var detail: String {
        if let proof = durableSnapshot.latestProof,
           !proof.title.localizedCaseInsensitiveContains("Project created") {
            return proof.detail
        }
        if let terminal = durableSnapshot.latestTerminalProof {
            let preview = terminal.outputPreview.isEmpty ? "Command finished." : terminal.outputPreview
            return "$ \(terminal.command) · \(preview)"
        }
        return durableSnapshot.reviewDetail.isEmpty ? "Capture proof for the latest work before final review." : durableSnapshot.reviewDetail
    }

    private var evidenceTrail: String {
        durableSnapshot.evidenceTrail
    }
}

private struct ArtifactHandoffCard: View {
    let artifact: WorkspaceArtifact
    let openArtifact: (WorkspaceArtifact) -> Void

    private var handoffText: String {
        if artifact.isSwiftGameArtifact {
            return "Open the native preview, then rotate sideways for handheld play."
        }
        if artifact.isPlayableWebArtifact {
            return "Open the live preview, then use Full Screen for landscape play."
        }
        if artifact.isWebPage {
            return "Open the responsive preview without switching into game mode."
        }
        return "Open the generated file in the workspace preview."
    }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: artifact.handoffSymbol)
                .font(.system(size: 16, weight: .black))
                .foregroundStyle(artifact.isWebPage || artifact.isSwiftGameArtifact ? AgentPalette.green : AgentPalette.cyan)
                .frame(width: 38, height: 38)
                .agentControlSurface(radius: 14, tint: (artifact.isWebPage || artifact.isSwiftGameArtifact ? AgentPalette.green : AgentPalette.cyan).opacity(0.14), selected: true)

            VStack(alignment: .leading, spacing: 3) {
                Text(artifact.title)
                    .font(.system(size: 12, weight: .black, design: AgentPalette.interfaceFontDesign))
                    .foregroundStyle(AgentPalette.ink)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(handoffText)
                    .font(.system(size: 9.5, weight: .semibold, design: AgentPalette.interfaceFontDesign))
                    .foregroundStyle(AgentPalette.secondaryText)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)

            Button {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                openArtifact(artifact)
            } label: {
                Label("Open", systemImage: "arrow.up.right.square.fill")
                    .font(.system(size: 10, weight: .black, design: AgentPalette.interfaceFontDesign))
                    .foregroundStyle(AgentPalette.ink)
                    .padding(.horizontal, 10)
                    .frame(height: AgentDesign.minimumTouchTarget)
                    .agentGlass(radius: 13, interactive: true, tint: AgentPalette.green.opacity(0.16))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open artifact preview for \(artifact.title)")
            .accessibilityIdentifier("artifactPrimaryOpenButton")
        }
        .padding(10)
        .agentRowSurface(radius: 16, tint: AgentPalette.green.opacity(0.06))
    }
}

private struct RunMetric: View {
    let value: String
    let label: String
    let symbol: String
    let tint: Color
    var valueIdentifier: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: symbol)
                    .font(.system(size: 8, weight: .heavy))
                Text(label)
                    .font(.system(size: 8, weight: .black, design: AgentPalette.interfaceFontDesign))
                    .textCase(.uppercase)
            }
            .foregroundStyle(AgentPalette.tertiaryText)
            Text(value)
                .font(.system(size: 13, weight: .black, design: AgentPalette.interfaceFontDesign))
                .foregroundStyle(AgentPalette.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
                .accessibilityIdentifier(valueIdentifier ?? "run\(label)Metric")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 9)
        .padding(.vertical, 8)
        .agentRowSurface(radius: 12, tint: tint.opacity(0.06))
    }
}

private struct ProgressDrawerLabel: View {
    let text: String
    let symbol: String
    let tint: Color

    var body: some View {
        Label(text, systemImage: symbol)
            .font(.system(size: 9, weight: .bold, design: AgentPalette.interfaceFontDesign))
            .foregroundStyle(tint)
            .textCase(.uppercase)
    }
}

private struct AgentTraceRow: View {
    let event: AgentTraceEvent
    let isFirst: Bool
    let isLast: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(spacing: 0) {
                Rectangle()
                    .fill(isFirst ? Color.clear : tint.opacity(0.24))
                    .frame(width: 2, height: 7)
                Image(systemName: symbol)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(tint)
                    .frame(width: 24, height: 24)
                    .agentSurface(radius: 8, tint: tint.opacity(0.10))
                Rectangle()
                    .fill(isLast ? Color.clear : tint.opacity(0.24))
                    .frame(width: 2)
            }
            .frame(width: 26)

            VStack(alignment: .leading, spacing: 3) {
                Text(displayTitle)
                    .font(.system(size: 11, weight: .bold, design: AgentPalette.interfaceFontDesign))
                    .foregroundStyle(AgentPalette.ink)
                    .lineLimit(1)
                    .accessibilityIdentifier(isFirst ? "latestTraceEventTitle" : "traceEventTitle")
                if !displayDetail.isEmpty {
                    Text(displayDetail)
                        .font(.system(size: 9, weight: .semibold, design: AgentPalette.interfaceFontDesign))
                        .foregroundStyle(AgentPalette.tertiaryText)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
            }
            .padding(.vertical, 7)

            Spacer(minLength: 0)

            Text(event.createdAt, style: .time)
                .font(.system(size: 8, weight: .semibold, design: .monospaced))
                .foregroundStyle(AgentPalette.tertiaryText)
                .padding(.top, 9)
        }
        .padding(.horizontal, 8)
    }

    private var displayTitle: String {
        let title = event.title
        for prefix in ["Finished", "Running", "Queued", "Approved", "Rejected"] {
            let marker = prefix + " "
            guard title.hasPrefix(marker) else { continue }
            let toolName = String(title.dropFirst(marker.count))
            switch prefix {
            case "Finished":
                return completedTitle(for: toolName)
            case "Running":
                return runningTitle(for: toolName)
            case "Queued":
                return "Queued \(plainToolName(toolName))"
            case "Approved":
                return "Approved \(plainToolName(toolName))"
            case "Rejected":
                return "Rejected \(plainToolName(toolName))"
            default:
                break
            }
        }
        return title
    }

    private var displayDetail: String {
        let cleaned = event.detail.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return "" }
        if let summary = jsonArgumentSummary(from: cleaned) {
            return summary
        }
        return cleaned
    }

    private func completedTitle(for toolName: String) -> String {
        switch toolName {
        case "write_file": "Wrote file"
        case "append_file": "Updated file"
        case "read_file": "Read file"
        case "list_directory": "Listed folder"
        case "search_text": "Searched workspace"
        case "validate_html_file": "Validated HTML"
        case "file_info": "Checked file info"
        case "run_command": "Ran command"
        case "make_directory": "Created folder"
        case "delete_path": "Deleted item"
        case "move_path": "Moved item"
        case "copy_path": "Copied item"
        default: "Finished \(plainToolName(toolName))"
        }
    }

    private func runningTitle(for toolName: String) -> String {
        switch toolName {
        case "write_file": "Writing file"
        case "append_file": "Updating file"
        case "read_file": "Reading file"
        case "list_directory": "Listing folder"
        case "search_text": "Searching workspace"
        case "validate_html_file": "Validating HTML"
        case "file_info": "Checking file info"
        case "run_command": "Running command"
        case "make_directory": "Creating folder"
        case "delete_path": "Deleting item"
        case "move_path": "Moving item"
        case "copy_path": "Copying item"
        default: "Running \(plainToolName(toolName))"
        }
    }

    private func plainToolName(_ toolName: String) -> String {
        toolName
            .replacingOccurrences(of: "_", with: " ")
            .capitalized
    }

    private func jsonArgumentSummary(from text: String) -> String? {
        guard text.hasPrefix("{") else { return nil }
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            if let path = roughJSONStringValue(for: "path", in: text) {
                return "path: \(shorten(path))"
            }
            if let command = roughJSONStringValue(for: "command", in: text) {
                return "command: \(shorten(command))"
            }
            if text.localizedCaseInsensitiveContains("contents") {
                return "file contents prepared"
            }
            return nil
        }
        for key in ["path", "file", "filename", "command", "query", "url", "name"] {
            if let value = object[key] as? String,
               !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return "\(key): \(shorten(value))"
            }
        }
        if let count = object["contents"].map({ "\($0)" })?.count {
            return "content prepared · \(count) chars"
        }
        return "\(object.count) argument\(object.count == 1 ? "" : "s") ready"
    }

    private func roughJSONStringValue(for key: String, in text: String) -> String? {
        let marker = "\"\(key)\":\""
        guard let startRange = text.range(of: marker) else { return nil }
        let valueStart = startRange.upperBound
        var value = ""
        var cursor = valueStart
        var escaped = false
        while cursor < text.endIndex {
            let character = text[cursor]
            if escaped {
                value.append(character)
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "\"" {
                break
            } else {
                value.append(character)
            }
            cursor = text.index(after: cursor)
        }
        return value.isEmpty ? nil : value
    }

    private func shorten(_ text: String) -> String {
        let oneLine = text
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
        guard oneLine.count > 88 else { return oneLine }
        return String(oneLine.prefix(88)) + "…"
    }

    private var symbol: String {
        switch event.status {
        case .queued: "tray.full.fill"
        case .thinking: "sparkles"
        case .planning: "map.fill"
        case .tool: "wrench.and.screwdriver.fill"
        case .approval: "checkmark.shield.fill"
        case .executing: "play.fill"
        case .paused: "pause.circle.fill"
        case .success: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        }
    }

    private var tint: Color {
        switch event.status {
        case .queued: AgentPalette.indigo
        case .thinking, .planning: AgentPalette.cyan
        case .tool, .executing: AgentPalette.cyan
        case .approval: AgentPalette.green
        case .paused: AgentPalette.cyan
        case .success: AgentPalette.green
        case .failed: AgentPalette.rose
        }
    }
}

private struct ProgressActionButton: View {
    let title: String
    let symbol: String
    let tint: Color
    var identifier: String? = nil
    let action: () -> Void

    var body: some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            action()
        } label: {
            Label(title, systemImage: symbol)
                .font(.system(size: 10, weight: .bold, design: AgentPalette.interfaceFontDesign))
                .foregroundStyle(AgentPalette.ink)
                .padding(.horizontal, 9)
                .frame(height: AgentDesign.minimumTouchTarget)
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
                .agentGlass(radius: 12, interactive: true, tint: tint.opacity(0.12))
        }
        .buttonStyle(.plain)
        .frame(minHeight: AgentDesign.minimumTouchTarget)
        .contentShape(Rectangle())
        .accessibilityIdentifier(identifier ?? "progress\(title)Button")
    }
}

private struct ProgressStatusIcon: View {
    let tint: Color

    var body: some View {
        ZStack {
            Circle()
                .stroke(AgentPalette.glassStroke.opacity(0.48), lineWidth: 2)
            Image(systemName: "hourglass")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(tint)
        }
        .frame(width: 22, height: 22)
    }
}

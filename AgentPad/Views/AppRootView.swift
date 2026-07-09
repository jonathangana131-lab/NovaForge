import SwiftData
import SwiftUI

/// Which tab is currently selected, delivered via the environment so that
/// tiny leaf views (tab backdrops) can react to tab switches WITHOUT the
/// whole TabView being re-keyed. Environment changes bypass the Equatable
/// render-key gates and invalidate only the views that actually read them.
private struct NovaActiveTabKey: EnvironmentKey {
    static let defaultValue: AppTab = .forge
}

extension EnvironmentValues {
    fileprivate var novaActiveTab: AppTab {
        get { self[NovaActiveTabKey.self] }
        set { self[NovaActiveTabKey.self] = newValue }
    }
}

/// Per-tab ambient backdrop that animates only while its tab is selected and
/// the scene is active. Reads the active tab from the environment, so a tab
/// switch re-renders just these two lightweight views — not the tab surfaces.
private struct TabActivatedBackground: View {
    let tab: AppTab
    @Environment(\.novaActiveTab) private var activeTab
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        AgentBackground(
            isWorking: false,
            isAnimated: scenePhase == .active && activeTab == tab
        )
    }
}

/// The four-tab architecture. NovaForge's loop — tell the agent, watch it
/// work, approve the risky step, see the result — used to be fractured
/// across five tabs that each re-explained the others. Now:
/// - Forge: the loop itself (chat + live mission + approvals in one place)
/// - Workspace: everything the agent made (files, artifacts, terminal)
/// - History: the auditable run trail
/// - Control: providers, models, autonomy, appearance
/// Projects are a context you're IN (scope pill on Forge), not a place you
/// go. The legacy five-tab vocabulary still routes via static aliases so
/// intents, fixtures, and older call sites keep working.
enum AppTab: String, CaseIterable, Identifiable {
    case forge
    case workspace
    case history
    case control

    var id: String { rawValue }

    var title: String {
        switch self {
        case .forge: "Forge"
        case .workspace: "Workspace"
        case .history: "History"
        case .control: "Control"
        }
    }

    var symbol: String {
        switch self {
        case .forge: "sparkles"
        case .workspace: "folder.fill"
        case .history: "waveform.path.ecg"
        case .control: "slider.horizontal.3"
        }
    }

    // MARK: Legacy routing aliases (old five-tab vocabulary)

    static var project: AppTab { .forge }
    static var chat: AppTab { .forge }
    static var files: AppTab { .workspace }
    static var runs: AppTab { .history }
    static var settings: AppTab { .control }
    static var terminal: AppTab { .workspace }

    /// Resolves both vocabularies ("chat" → .forge, "history" → .history)
    /// so Siri intents and notification handoffs from either era work.
    static func resolve(_ rawValue: String) -> AppTab? {
        if let tab = AppTab(rawValue: rawValue) { return tab }
        switch rawValue {
        case "project", "chat", "forge": return .forge
        case "files", "terminal", "workspace": return .workspace
        case "runs", "history": return .history
        case "settings", "control": return .control
        default: return nil
        }
    }
}

private extension AppTab {
    var performanceIndex: Double {
        switch self {
        case .forge: 0
        case .workspace: 1
        case .history: 2
        case .control: 3
        }
    }
}

@MainActor
struct AppRootView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Query private var projects: [Project]
    @Query private var conversations: [Conversation]
    @Query private var settingsList: [AgentSettings]
    @State private var selectedTab = Self.initialDebugLaunchTab()
    @State private var showingMissionDossier = false
    @State private var runtime = AgentRuntime()
    @State private var projectRuntime = AgentRuntime()
    @State private var selectedConversationID: UUID?
    @State private var optimisticSelectedConversation: Conversation?
    @State private var landscapeGameArtifact: WorkspaceArtifact?
    @State private var terminalFocus: TerminalConsoleFocusRequest?
    @State private var rootPrompt = ""
    @State private var rootPromptRevision = 0
    @State private var rootError: String?
    @State private var pendingTabSwitch: AppTab?
    @State private var tabSwitchStartedAt: Date?
    @State private var didRunAutoTabSwitchProfile = false
    @State private var autoContinueCountdownProjectID: UUID?
    @State private var autoContinueCountdownSourceEventID: String?
    @State private var autoContinueRemainingSeconds = 0
    @State private var autoContinueCountdownTitle = ""
    @State private var autoContinueCountdownDetail = ""
    @State private var autoContinueCountdownTask: Task<Void, Never>?
    @State private var pendingProjectRunDispatchID: UUID?
    #if DEBUG || targetEnvironment(simulator)
    @State private var didInjectNetworkFailureFixture = false
    @State private var didInjectPendingApprovalFixture = false
    @State private var didInjectLocalAgentBoundaryFixture = false
    @State private var didInjectArtifactDedupeFixture = false
    @State private var didInjectWebPageArtifactFixture = false
    @State private var didInjectSwiftGameArtifactFixture = false
    @State private var didInjectComposerSendResponseFixture = false
    @State private var didInjectProjectContinuationFixture = false
    @State private var didInjectLiveTerminalRecordFixture = false
    @State private var didInjectProjectRunningFixture = false
    @State private var didInjectProjectBlockedFixture = false
    @State private var didInjectProjectProofFixture = false
    @State private var didInjectProjectWaitingFixture = false
    @State private var didInjectProjectResumeFixture = false
    @State private var didInjectAutoContinueCountdownFixture = false
    @State private var didInjectProjectSpineE2EFixture = false
    @State private var didInjectRunsApprovalFixture = false
    @State private var debugLaunchTaskRetryCount = 0
    #endif
    @AppStorage(AgentTheme.storageKey) private var selectedThemeRawValue = AgentTheme.defaultTheme.rawValue
    @AppStorage(AgentPerformance.storageKey) private var performanceModeEnabled = false
    @AppStorage(LaunchConversationSelection.persistedSelectionKey) private var persistedSelectedConversationID = ""

    init() {
        var projectsDescriptor = FetchDescriptor<Project>(
            sortBy: [SortDescriptor(\Project.lastActivityAt, order: .reverse)]
        )
        projectsDescriptor.fetchLimit = 20
        _projects = Query(projectsDescriptor)

        var conversationsDescriptor = FetchDescriptor<Conversation>(
            sortBy: [SortDescriptor(\Conversation.updatedAt, order: .reverse)]
        )
        conversationsDescriptor.fetchLimit = 80
        _conversations = Query(conversationsDescriptor)

        var settingsDescriptor = FetchDescriptor<AgentSettings>()
        settingsDescriptor.fetchLimit = 1
        _settingsList = Query(settingsDescriptor)
    }

    private var selectedConversation: Conversation? {
        if let optimisticSelectedConversation,
           optimisticSelectedConversation.id == selectedConversationID {
            return optimisticSelectedConversation
        }
        #if DEBUG || targetEnvironment(simulator)
        if shouldPreferDebugSeededConversation,
           let persistedID = UUID(uuidString: persistedSelectedConversationID),
           let seeded = conversations.first(where: { $0.id == persistedID }) {
            return seeded
        }
        #endif
        return LaunchConversationSelection.preferredConversation(
            from: conversations,
            sessionID: selectedConversationID,
            persistedIDString: persistedSelectedConversationID
        )
    }

    #if DEBUG || targetEnvironment(simulator)
    private var shouldPreferDebugSeededConversation: Bool {
        let arguments = ProcessInfo.processInfo.arguments
        return arguments.contains("--stress-chat") ||
            arguments.contains("--stress-tool-batch") ||
            arguments.contains("--running-tool-call-demo") ||
            arguments.contains("--failed-tool-call-demo") ||
            arguments.contains("--code-block-demo")
    }
    #endif

    private var settings: AgentSettings? { settingsList.first }
    private var activeProject: Project? {
        ProjectBootstrap.preferredProject(from: projects, settings: settings)
    }
    private var usesDebugTerminalSurface: Bool {
        #if DEBUG || targetEnvironment(simulator)
        return ProcessInfo.processInfo.arguments.contains("--open-terminal")
        #else
        return false
        #endif
    }
    private var autoContinueRuntimeSignature: AutoContinueRuntimeSignature {
        AutoContinueRuntimeSignature(project: activeProject, runtime: projectRuntime)
    }

    var body: some View {
        // No AnyView here: wrapping the root in AnyView erased SwiftUI's
        // structural identity for the entire tree, degrading diffing on every
        // root state change. Profiling side effects live in a helper instead.
        let _ = Self.recordRootBodyProfiling()
        rootContentWithLifecycle
    }

    private static func recordRootBodyProfiling() {
        #if DEBUG
        if AgentPerformance.shouldProfileViewChanges {
            Self._printChanges()
        }
        #endif
        _ = AgentPerformance.bodyEvaluation("App Root Body")
    }

    private var rootContentWithLifecycle: some View {
        rootContent
        .environment(\.novaActiveTab, selectedTab)
        .task {
            runRootLaunchTasks()
        }
        .onReceive(NotificationCenter.default.publisher(for: NovaForgeIntentSignal.openTab)) { note in
            guard let raw = note.userInfo?[NovaForgeIntentSignal.tabKey] as? String,
                  let tab = AppTab.resolve(raw) else { return }
            selectedTab = tab
        }
        .onReceive(NotificationCenter.default.publisher(for: NovaForgeIntentSignal.askPrompt)) { _ in
            // ChatView owns the composer prefill; the root just lands on Forge.
            selectedTab = .forge
        }
        .onChange(of: settings?.activeWorkspaceName, initial: true) { _, newValue in
            repairActiveWorkspaceNameChange(newValue)
        }
        .onChange(of: activeProject?.id, initial: true) {
            if let activeProject {
                clearInactiveRuntimeForConversationSwitch()
                rootPrompt = ""
                landscapeGameArtifact = nil
                syncRuntimeWorkspaceForCurrentSurface(activeProject: activeProject)
                #if DEBUG || targetEnvironment(simulator)
                applyDebugLaunchTabArgument()
                #endif
            }
        }
        .onChange(of: selectedConversation?.id) {
            rootPrompt = ""
            if let activeProject {
                syncRuntimeWorkspaceForCurrentSurface(activeProject: activeProject)
            }
            persistSelectedConversationIfSafe()
        }
        .onChange(of: selectedConversation?.updatedAt) {
            persistSelectedConversationIfSafe()
        }
        .onChange(of: selectedConversation?.messageCount) {
            persistSelectedConversationIfSafe()
        }
        .onChange(of: selectedTab) { oldValue, newValue in
            startTabSwitch(from: oldValue, to: newValue)
            if let activeProject {
                syncRuntimeWorkspaceForCurrentSurface(activeProject: activeProject)
            }
        }
        .onChange(of: autoContinueRuntimeSignature) {
            reconcileAutoContinue()
        }
        .onChange(of: selectedThemeRawValue, initial: true) { _, newValue in
            let theme = AgentTheme.resolved(from: newValue)
            if newValue != theme.rawValue {
                selectedThemeRawValue = theme.rawValue
            }
            AgentPalette.refreshThemeCache(theme)
            AgentThemeUIKit.apply(theme)
        }
        .onChange(of: performanceModeEnabled, initial: true) { _, _ in
            AgentPerformance.invalidatePerformanceModeCache()
        }
        .fullScreenCover(item: $terminalFocus, content: terminalConsoleCover)
        .fullScreenCover(isPresented: $showingMissionDossier) {
            missionDossierCover
        }
        .alert(
            "NovaForge Save Failed",
            isPresented: Binding(
                get: { rootError != nil },
                set: { if !$0 { rootError = nil } }
            )
        ) {
            Button("OK", role: .cancel) { rootError = nil }
        } message: {
            Text(rootError ?? "NovaForge could not save this change.")
        }
    }

    private var rootContent: some View {
        ZStack {
            let hasPrimaryAppContent = selectedConversation != nil && settings != nil && activeProject != nil
            AgentBackground(
                isWorking: false,
                isAnimated: scenePhase == .active && !hasPrimaryAppContent
            )
            .id("\(selectedThemeRawValue)-\(performanceModeEnabled)")
            .ignoresSafeArea()

            if let conversation = selectedConversation, let settings, let activeProject {
                if usesDebugTerminalSurface {
                    TerminalConsoleView(runtime: runtime, project: activeProject, openChat: {
                        openTab(.chat)
                    })
                } else {
                    appTabSurface(conversation: conversation, settings: settings, activeProject: activeProject)
                }
            } else {
                launchRecoveryPanel
            }

            ArtifactLandscapeGameModalPresenter(
                artifact: landscapeGameArtifact,
                workspace: runtime.workspace,
                close: {
                    self.landscapeGameArtifact = nil
                }
            )
            .frame(width: 1, height: 1)
            .allowsHitTesting(false)

            rootToastLayer
        }
    }

    private var rootToastLayer: some View {
        VStack {
            Spacer()
            VStack(spacing: 8) {
                ForEach(runtime.toasts) { toast in
                    AgentToastView(toast: toast) {
                        runtime.dismissToast(toast)
                    }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
            .animation(.spring(duration: 0.35), value: runtime.toasts)
        }
        .allowsHitTesting(!runtime.toasts.isEmpty)
    }

    private func runRootLaunchTasks() {
        AgentPerformance.event("App Launch")
        repairRequiredLaunchRecords()
        repairActiveProjectIfNeeded()
        repairRootStaleModelSelection()
        reconcileLaunchSelection()
        runtime.ensureSeedWorkspace()
        projectRuntime.ensureSeedWorkspace()
        #if DEBUG || targetEnvironment(simulator)
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--stress-streaming"), !runtime.isWorking {
            if let conversation = selectedConversation, conversation.messageCount == 0 {
                seedStreamingStressConversation(conversation)
                try? modelContext.save()
            }
            runtime.simulateStreamingStress()
        }
        #endif
        scheduleAutoTabSwitchProfileIfNeeded()
        #if DEBUG || targetEnvironment(simulator)
        runDebugLaunchTasks(arguments: arguments)
        #endif
    }

    #if DEBUG || targetEnvironment(simulator)
    private func hasDebugLaunchFlag(_ flag: String, in arguments: [String]) -> Bool {
        arguments.contains(flag) ||
        arguments.joined(separator: " ").contains(flag) ||
        arguments.contains { argument in
            argument == flag ||
            argument.hasPrefix("\(flag)=") ||
            argument.split(whereSeparator: { $0.isWhitespace }).contains(Substring(flag))
        }
    }

    private func runDebugLaunchTasks(arguments: [String]) {
        if arguments.contains("--simulate-network-failure"),
           runtime.lastError == nil,
           !didInjectNetworkFailureFixture {
            didInjectNetworkFailureFixture = true
            runtime.simulateRecoverableFailure()
        }
        if arguments.contains("--active-status-strip") {
            startDebugActiveStatusStripRunIfPossible()
        }
        if arguments.contains("--stale-openai-local-model"),
           let settings {
            selectedTab = .chat
            settings.providerRawValue = AIProvider.openAI.rawValue
            settings.modelID = AIProvider.local.defaultModel
            settings.updatedAt = Date()
            try? modelContext.save()
        }
        if arguments.contains("--first-run-local-model-missing"),
           let settings {
            selectedTab = .chat
            settings.provider = .local
            settings.modelID = LocalModelCatalog.defaultVariant.id
            settings.updatedAt = Date()
            runtime.localModels.select(LocalModelCatalog.defaultVariant)
            try? modelContext.save()
        }
        if arguments.contains("--settings-local-model-ready"),
           let settings {
            selectedTab = .settings
            settings.provider = .local
            settings.modelID = LocalModelCatalog.defaultVariant.id
            settings.updatedAt = Date()
            runtime.localModels.select(LocalModelCatalog.defaultVariant)
            runtime.localModels.debugOverrideStatusForUITest(.ready)
            try? modelContext.save()
        }
        if arguments.contains("--settings-local-model-partial"),
           let settings {
            selectedTab = .settings
            settings.provider = .local
            settings.modelID = LocalModelCatalog.defaultVariant.id
            settings.updatedAt = Date()
            runtime.localModels.select(LocalModelCatalog.defaultVariant)
            runtime.localModels.debugOverrideStatusForUITest(.partial, receivedBytes: LocalModelCatalog.defaultVariant.expectedBytes / 3)
            try? modelContext.save()
        }
        repairRootStaleModelSelection()
        applyDebugLaunchTabArgument()
        if arguments.contains("--terminal-live-record-demo"),
           let activeProject,
           !didInjectLiveTerminalRecordFixture {
            scheduleLiveTerminalRecordFixture(for: activeProject)
        }
        if arguments.contains("--auto-continue-project"),
           let activeProject,
           let settings,
           !runtime.isWorking,
           !didInjectProjectContinuationFixture {
            didInjectProjectContinuationFixture = true
            settings.provider = .openAI
            settings.modelID = AIProvider.openAI.defaultModel
            settings.temperature = min(settings.temperature, 0.2)
            settings.updatedAt = Date()
            runtime.debugInstallProviderResponses([
                ProviderResponse(
                    message: ChatCompletionsResponse.Choice.Message(
                        role: "assistant",
                        content: "Continuation complete. I checked the project evidence, found no blockers yet, and queued the next safe build step.",
                        tool_calls: nil
                    ),
                    roleLog: "debug project continuation completion"
                )
            ])
            try? modelContext.save()
            continueProject(activeProject)
        }
        if arguments.contains("--resume-local-model-download") {
            if let modelID = settings?.modelID,
               let variant = LocalModelCatalog.variant(for: modelID) {
                runtime.localModels.select(variant)
            }
            runtime.localModels.downloadSelected()
        }
        runDebugChatLaunchTasks(arguments: arguments)
        runDebugProjectLaunchTasks(arguments: arguments)
        applyDebugLaunchTabArgument()
        scheduleDebugLaunchTaskRetryIfNeeded(arguments: arguments)
    }

    private func startDebugActiveStatusStripRunIfPossible(retryCount: Int = 0) {
        guard !runtime.isWorking || runtime.activeConversationID == nil else { return }
        guard let conversation = selectedConversation
            ?? LaunchConversationSelection.preferredConversation(
                from: conversations,
                sessionID: selectedConversationID,
                persistedIDString: persistedSelectedConversationID
            )
            ?? conversations.first else {
            guard retryCount < 3 else { return }
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(100))
                startDebugActiveStatusStripRunIfPossible(retryCount: retryCount + 1)
            }
            return
        }

        if selectedConversationID == nil {
            selectedConversationID = conversation.id
        }
        runtime.debugSimulateActiveStatusStripRun(conversation: conversation)
    }

    private func startDebugProjectStatusRunIfPossible(retryCount: Int = 0) {
        guard !projectRuntime.isWorking || projectRuntime.activeConversationID == nil else { return }
        guard let conversation = selectedConversation
            ?? LaunchConversationSelection.preferredConversation(
                from: conversations,
                sessionID: selectedConversationID,
                persistedIDString: persistedSelectedConversationID
            )
            ?? conversations.first else {
            guard retryCount < 3 else { return }
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(100))
                startDebugProjectStatusRunIfPossible(retryCount: retryCount + 1)
            }
            return
        }

        projectRuntime.debugSimulateActiveStatusStripRun(conversation: conversation)
    }

    private func runDebugChatLaunchTasks(arguments: [String]) {
        if arguments.contains("--local-smoke-test"),
           let conversation = selectedConversation,
           let settings,
           !runtime.isWorking {
            selectedTab = .chat
            settings.provider = .local
            settings.modelID = LocalModelCatalog.defaultVariant.id
            settings.temperature = min(settings.temperature, 0.2)
            settings.updatedAt = Date()
            try? modelContext.save()
            runtime.localModels.select(LocalModelCatalog.defaultVariant)
            runtime.send(
                prompt: "Reply with one short sentence: local model is working.",
                conversation: conversation,
                settings: settings,
                context: modelContext,
                project: activeProject
            )
        }
        if arguments.contains("--local-agent-boundary-test"),
           let conversation = selectedConversation,
           !runtime.isWorking,
           !didInjectLocalAgentBoundaryFixture {
            didInjectLocalAgentBoundaryFixture = true
            selectedTab = .chat
            installLocalAgentBoundaryFixture(in: conversation)
            try? modelContext.save()
        }
        if arguments.contains("--composer-send-response-test"),
           let settings,
           !runtime.isWorking,
           !didInjectComposerSendResponseFixture {
            didInjectComposerSendResponseFixture = true
            selectedTab = .chat
            settings.provider = .openAI
            settings.modelID = AIProvider.openAI.defaultModel
            settings.temperature = min(settings.temperature, 0.2)
            settings.updatedAt = Date()
            runtime.debugInstallProviderResponses([
                ProviderResponse(
                    message: ChatCompletionsResponse.Choice.Message(
                        role: "assistant",
                        content: "I can inspect files, plan changes, run builds, and capture proof screenshots.",
                        tool_calls: nil
                    ),
                    roleLog: "debug composer send response"
                )
            ])
            try? modelContext.save()
        }
        if arguments.contains("--local-web-artifact-test"),
           let conversation = selectedConversation,
           !runtime.isWorking,
           !didInjectWebPageArtifactFixture {
            didInjectWebPageArtifactFixture = true
            selectedTab = .chat
            installCompletedWebPageArtifactFixture(in: conversation)
            try? modelContext.save()
        }
        if hasDebugLaunchFlag("--swift-game-artifact-demo", in: arguments),
           let conversation = selectedConversation,
           !runtime.isWorking,
           !didInjectSwiftGameArtifactFixture {
            didInjectSwiftGameArtifactFixture = true
            selectedTab = .chat
            installCompletedSwiftGameArtifactFixture(in: conversation)
            try? modelContext.save()
        }
        if hasDebugLaunchFlag("--pending-approval-demo", in: arguments),
           !hasDebugLaunchFlag("--open-project", in: arguments),
           let conversation = selectedConversation,
           let settings,
           runtime.pendingTool == nil,
           !runtime.isWorking,
           !didInjectPendingApprovalFixture {
            didInjectPendingApprovalFixture = true
            selectedTab = .chat
            settings.provider = .openAI
            settings.modelID = AIProvider.openAI.defaultModel
            settings.temperature = min(settings.temperature, 0.2)
            settings.updatedAt = Date()
            runtime.debugInstallProviderResponses([
                ProviderResponse(
                    message: ChatCompletionsResponse.Choice.Message(
                        role: "assistant",
                        content: "Run complete. The approval demo artifact has been written.",
                        tool_calls: nil
                    ),
                    roleLog: "debug pending approval completion"
                )
            ])
            installPendingApprovalFixture(in: conversation)
            try? modelContext.save()
        }
        if arguments.contains("--artifact-dedupe-demo"),
           let conversation = selectedConversation,
           !runtime.isWorking,
           !didInjectArtifactDedupeFixture {
            didInjectArtifactDedupeFixture = true
            selectedTab = .chat
            installCompletedArtifactFixture(in: conversation)
            try? modelContext.save()
        }
    }

    private func runDebugProjectLaunchTasks(arguments: [String]) {
        let shouldInstallProjectApprovalDemo = hasDebugLaunchFlag("--project-waiting-demo", in: arguments) ||
            (hasDebugLaunchFlag("--pending-approval-demo", in: arguments) && hasDebugLaunchFlag("--open-project", in: arguments))
        if hasDebugLaunchFlag("--project-running-demo", in: arguments),
           let activeProject,
           !didInjectProjectRunningFixture {
            didInjectProjectRunningFixture = true
            selectedTab = .project
            let conversation = projectConversation(for: activeProject, now: Date())
            installProjectRunningFixture(for: activeProject, conversation: conversation)
            preserveGeneralChatSelection()
            try? modelContext.save()
        }
        if hasDebugLaunchFlag("--project-blocked-demo", in: arguments),
           let activeProject,
           !didInjectProjectBlockedFixture {
            didInjectProjectBlockedFixture = true
            selectedTab = .project
            let conversation = projectConversation(for: activeProject, now: Date())
            installProjectBlockedFixture(for: activeProject, conversation: conversation)
            preserveGeneralChatSelection()
            try? modelContext.save()
        }
        if shouldInstallProjectApprovalDemo,
           let activeProject,
           !didInjectProjectWaitingFixture {
            didInjectProjectWaitingFixture = true
            selectedTab = .project
            let conversation = projectConversation(for: activeProject, now: Date())
            installProjectWaitingFixture(for: activeProject, conversation: conversation)
            preserveGeneralChatSelection()
            try? modelContext.save()
        }
        if hasDebugLaunchFlag("--project-resume-demo", in: arguments),
           let activeProject,
           !didInjectProjectResumeFixture {
            didInjectProjectResumeFixture = true
            selectedTab = .project
            let conversation = projectConversation(for: activeProject, now: Date())
            installProjectResumeFixture(for: activeProject, conversation: conversation)
            preserveGeneralChatSelection()
            try? modelContext.save()
        }
        // Deterministic Runs-tab approval capture. The generic
        // --pending-approval-demo forces selectedTab = .chat (its sheet is a
        // chat surface), which raced --open-runs in the CI tour. This flag
        // installs the same durable saved-approval evidence but keeps the
        // Runs tab in front.
        if hasDebugLaunchFlag("--runs-approval-demo", in: arguments),
           let activeProject,
           !didInjectRunsApprovalFixture {
            didInjectRunsApprovalFixture = true
            selectedTab = .runs
            let conversation = projectConversation(for: activeProject, now: Date())
            installProjectWaitingFixture(for: activeProject, conversation: conversation)
            preserveGeneralChatSelection()
            try? modelContext.save()
            // Late conversation-selection bootstrap can steal the tab back to
            // chat after this fixture runs (run 34, shot 19). Re-assert after
            // the launch dust settles — the CI screenshot fires at +9s.
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(2_500))
                selectedTab = .runs
            }
        }
        if hasDebugLaunchFlag("--project-proof-demo", in: arguments),
           let activeProject,
           !didInjectProjectProofFixture {
            didInjectProjectProofFixture = true
            selectedTab = .project
            let conversation = projectConversation(for: activeProject, now: Date())
            installProjectProofFixture(for: activeProject, conversation: conversation)
            preserveGeneralChatSelection()
            try? modelContext.save()
        }
        if hasDebugLaunchFlag("--project-spine-e2e-demo", in: arguments),
           let activeProject,
           !didInjectProjectSpineE2EFixture {
            didInjectProjectSpineE2EFixture = true
            selectedTab = hasDebugLaunchFlag("--open-chat", in: arguments) ? .chat : selectedTab
            let conversation = projectConversation(for: activeProject, now: Date())
            installProjectSpineE2EFixture(for: activeProject, conversation: conversation)
            if hasDebugLaunchFlag("--open-project-chat", in: arguments) {
                selectedConversationID = conversation.id
                persistedSelectedConversationID = conversation.id.uuidString
            } else {
                preserveGeneralChatSelection()
            }
            if hasDebugLaunchFlag("--workbench-open-artifact-landscape-preview", in: arguments) {
                selectedTab = .files
                landscapeGameArtifact = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                    if hasDebugLaunchFlag("--workbench-open-artifact-landscape-preview", in: ProcessInfo.processInfo.arguments) {
                        landscapeGameArtifact = WorkspaceArtifact(path: "workflow-spine-proof.html")
                    }
                }
            }
            try? modelContext.save()
        }
        if hasDebugLaunchFlag("--auto-continue-countdown-demo", in: arguments),
           let activeProject,
           let settings,
           !didInjectAutoContinueCountdownFixture {
            didInjectAutoContinueCountdownFixture = true
            selectedTab = .project
            let conversation = projectConversation(for: activeProject, now: Date())
            installAutoContinueCountdownFixture(
                for: activeProject,
                conversation: conversation,
                settings: settings
            )
            preserveGeneralChatSelection()
        }
    }

    private func scheduleDebugLaunchTaskRetryIfNeeded(arguments: [String]) {
        guard debugLaunchTaskRetryCount < 8,
              hasPendingDebugLaunchFixture(arguments) else { return }
        debugLaunchTaskRetryCount += 1
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(150))
            runDebugLaunchTasks(arguments: arguments)
        }
    }

    private func hasPendingDebugLaunchFixture(_ arguments: [String]) -> Bool {
        if hasDebugLaunchFlag("--pending-approval-demo", in: arguments),
           !hasDebugLaunchFlag("--open-project", in: arguments),
           !didInjectPendingApprovalFixture {
            return true
        }
        if hasDebugLaunchFlag("--local-agent-boundary-test", in: arguments), !didInjectLocalAgentBoundaryFixture {
            return true
        }
        if hasDebugLaunchFlag("--local-web-artifact-test", in: arguments), !didInjectWebPageArtifactFixture {
            return true
        }
        if hasDebugLaunchFlag("--artifact-dedupe-demo", in: arguments), !didInjectArtifactDedupeFixture {
            return true
        }
        if hasDebugLaunchFlag("--terminal-live-record-demo", in: arguments), !didInjectLiveTerminalRecordFixture {
            return true
        }
        if hasDebugLaunchFlag("--project-running-demo", in: arguments), !didInjectProjectRunningFixture {
            return true
        }
        if hasDebugLaunchFlag("--project-blocked-demo", in: arguments), !didInjectProjectBlockedFixture {
            return true
        }
        let shouldInstallProjectApprovalDemo = hasDebugLaunchFlag("--project-waiting-demo", in: arguments) ||
            (hasDebugLaunchFlag("--pending-approval-demo", in: arguments) && hasDebugLaunchFlag("--open-project", in: arguments))
        if shouldInstallProjectApprovalDemo, !didInjectProjectWaitingFixture {
            return true
        }
        if hasDebugLaunchFlag("--project-resume-demo", in: arguments), !didInjectProjectResumeFixture {
            return true
        }
        if hasDebugLaunchFlag("--runs-approval-demo", in: arguments), !didInjectRunsApprovalFixture {
            return true
        }
        if hasDebugLaunchFlag("--project-proof-demo", in: arguments), !didInjectProjectProofFixture {
            return true
        }
        if hasDebugLaunchFlag("--project-spine-e2e-demo", in: arguments), !didInjectProjectSpineE2EFixture {
            return true
        }
        if hasDebugLaunchFlag("--auto-continue-countdown-demo", in: arguments), !didInjectAutoContinueCountdownFixture {
            return true
        }
        if hasDebugLaunchFlag("--swift-game-artifact-demo", in: arguments), !didInjectSwiftGameArtifactFixture {
            return true
        }
        return false
    }
    #endif

    @ViewBuilder
    private func appTabSurface(
        conversation: Conversation,
        settings: AgentSettings,
        activeProject: Project
    ) -> some View {
        #if DEBUG || targetEnvironment(simulator)
        let forceProjectChat = hasDebugLaunchFlag("--open-project-chat", in: ProcessInfo.processInfo.arguments)
        #else
        let forceProjectChat = false
        #endif
        let chatConversation = forceProjectChat
            ? conversation
            : (conversation.project == nil ? conversation : (preferredGeneralConversation() ?? conversation))
        // The mission strip lives on Forge, so project runtime status is
        // computed while Forge is front (and while the dossier is open).
        let projectRuntimeStatus = selectedTab == .forge || showingMissionDossier
            ? WorkspaceStatusSnapshot(runtime: projectRuntime)
            : .hidden
        let projectAutoContinueState = autoContinueViewState(for: activeProject, settings: settings)
        let chatProfilingVisible = AgentPerformance.shouldProfileFrameRate && selectedTab == .forge
        let appTabsRenderKey = AppTabsRenderKey(
            project: activeProject,
            conversation: chatConversation,
            settings: settings,
            runtimeStatus: projectRuntimeStatus,
            selectedTab: selectedTab,
            projectResumeDraftRevision: rootPromptRevision,
            autoContinueState: projectAutoContinueState,
            themeRawValue: selectedThemeRawValue,
            performanceModeEnabled: performanceModeEnabled
        )
        let chatTabRenderKey = ChatTabKey(
            project: activeProject,
            conversation: chatConversation,
            conversations: conversations,
            settings: settings,
            projectResumeDraftRevision: rootPromptRevision,
            missionStatus: projectRuntimeStatus,
            missionAutoContinue: projectAutoContinueState,
            isVisibleForFrameProfiling: chatProfilingVisible,
            themeRawValue: selectedThemeRawValue,
            performanceModeEnabled: performanceModeEnabled
        )
        let filesTabRenderKey = FilesTabKey(
            project: activeProject,
            isVisible: false,
            themeRawValue: selectedThemeRawValue,
            performanceModeEnabled: performanceModeEnabled
        )
        let runsTabRenderKey = RunsTabKey(
            project: activeProject,
            isVisible: false,
            themeRawValue: selectedThemeRawValue,
            performanceModeEnabled: performanceModeEnabled
        )
        let settingsTabRenderKey = SettingsTabKey(
            project: activeProject,
            settings: settings,
            isVisible: false,
            themeRawValue: selectedThemeRawValue,
            performanceModeEnabled: performanceModeEnabled
        )

        StableTabSurface(key: appTabsRenderKey) {
            let _ = AgentPerformance.bodyEvaluation("App Tabs Body")
            TabView(selection: $selectedTab) {
                forgeTab(
                    key: chatTabRenderKey,
                    project: activeProject,
                    conversation: chatConversation,
                    missionConversation: conversation,
                    settings: settings,
                    runtimeStatus: projectRuntimeStatus,
                    autoContinueState: projectAutoContinueState
                )
                filesTab(key: filesTabRenderKey, project: activeProject)
                runsTab(key: runsTabRenderKey, project: activeProject, conversation: conversation, settings: settings)
                settingsTab(key: settingsTabRenderKey, project: activeProject, settings: settings)
            }
            .tint(AgentPalette.dockSelectedTint)
        }
        .equatable()
    }

    /// Forge: the loop surface. Chat, the live mission strip, and inline
    /// approvals in one place. The full project dossier presents modally.
    private func forgeTab(
        key: ChatTabKey,
        project: Project,
        conversation: Conversation,
        missionConversation: Conversation,
        settings: AgentSettings,
        runtimeStatus: WorkspaceStatusSnapshot,
        autoContinueState: ProjectAutoContinueViewState
    ) -> some View {
        StableTabSurface(key: key) {
            tabWorldSurface(for: .forge) {
                ChatView(
                    runtime: runtime,
                    project: project,
                    projects: projects,
                    conversation: conversation,
                    conversations: conversations,
                    settings: settings,
                    newChat: createConversation,
                    selectConversation: {
                        selectConversation($0)
                    },
                    setConversationProjectScope: setConversationProjectScope,
                    projectResumeDraft: rootPrompt,
                    projectResumeDraftRevision: rootPromptRevision,
                    openWorkspaceSurface: openTab,
                    openArtifactLandscapeFullScreen: openArtifactLandscapeFullScreen,
                    isVisibleForFrameProfiling: key.isVisibleForFrameProfiling,
                    missionStatus: runtimeStatus,
                    missionAutoContinue: autoContinueState,
                    approveMissionTool: {
                        projectRuntime.approvePendingTool(conversation: missionConversation, settings: settings, context: modelContext, project: project)
                    },
                    rejectMissionTool: {
                        projectRuntime.rejectPendingTool(conversation: missionConversation, settings: settings, context: modelContext, project: project)
                    },
                    stopMissionRun: {
                        projectRuntime.stopGenerating(context: modelContext)
                    },
                    pauseMissionAutoContinue: { pauseAutoContinue(project) },
                    openMissionDossier: presentMissionDossier,
                    createProject: { createProject() }
                )
            }
        }
        .equatable()
        .onAppear { completeTabSwitch(to: .forge) }
        .tabItem { Label(AppTab.forge.title, systemImage: AppTab.forge.symbol) }
        .tag(AppTab.forge)
    }

    private func filesTab(key: FilesTabKey, project: Project) -> some View {
        StableTabSurface(key: key) {
            tabWorldSurface(for: .workspace) {
                FilesView(
                    runtime: runtime,
                    project: project,
                    openArtifactLandscapeFullScreen: openArtifactLandscapeFullScreen
                ) {
                    openTab(.forge)
                }
            }
        }
        .equatable()
        .onAppear { completeTabSwitch(to: .workspace) }
        .tabItem { Label(AppTab.workspace.title, systemImage: AppTab.workspace.symbol) }
        .tag(AppTab.workspace)
    }

    private func runsTab(key: RunsTabKey, project: Project, conversation: Conversation, settings: AgentSettings) -> some View {
        StableTabSurface(key: key) {
            tabWorldSurface(for: .history) {
                RunsView(
                    runtime: projectRuntime,
                    project: project,
                    openArtifactLandscapeFullScreen: openArtifactLandscapeFullScreen,
                    openTerminalRecord: openTerminalRecord,
                    openProject: presentMissionDossier,
                    approvePendingTool: {
                        projectRuntime.approvePendingTool(conversation: conversation, settings: settings, context: modelContext, project: project)
                    },
                    rejectPendingTool: {
                        projectRuntime.rejectPendingTool(conversation: conversation, settings: settings, context: modelContext, project: project)
                    }
                ) {
                    openTab(.forge)
                }
            }
        }
        .equatable()
        .onAppear { completeTabSwitch(to: .history) }
        .tabItem { Label(AppTab.history.title, systemImage: AppTab.history.symbol) }
        .tag(AppTab.history)
    }

    private func settingsTab(key: SettingsTabKey, project: Project, settings: AgentSettings) -> some View {
        StableTabSurface(key: key) {
            tabWorldSurface(for: .control) {
                SettingsView(runtime: runtime, project: project, settings: settings)
            }
        }
        .equatable()
        .onAppear { completeTabSwitch(to: .control) }
        .tabItem { Label(AppTab.control.title, systemImage: AppTab.control.symbol) }
        .tag(AppTab.control)
    }

    private func tabWorldSurface<Content: View>(
        for tab: AppTab,
        @ViewBuilder content: () -> Content
    ) -> some View {
        ZStack {
            TabActivatedBackground(tab: tab)
            .id("tab-\(tab.rawValue)-\(selectedThemeRawValue)-\(performanceModeEnabled)")
            .ignoresSafeArea()
            .compositingGroup()
            .zIndex(0)

            content()
                .zIndex(1)

            if tab != .forge {
                DockGutterScrim()
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .ignoresSafeArea(edges: .bottom)
                    .zIndex(1.5)
            }

            tabWorldMotionOverlay(for: tab)
                .zIndex(2)
        }
    }

    @ViewBuilder
    private func tabWorldMotionOverlay(for tab: AppTab) -> some View {
        EmptyView()
    }

    private func openArtifactLandscapeFullScreen(_ artifact: WorkspaceArtifact) {
        landscapeGameArtifact = artifact
    }

    private func openTerminalRecord(id: UUID, command: String, query: String) {
        terminalFocus = TerminalConsoleFocusRequest(id: id, command: command, query: query)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    private func presentMissionDossier() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        showingMissionDossier = true
    }

    /// The project deep dive (plan, ledger, proof, project switching) as a
    /// modal dossier. Ambient mission state lives on Forge's mission strip;
    /// this cover is the on-demand full view that used to occupy a tab.
    @ViewBuilder
    private var missionDossierCover: some View {
        if let conversation = selectedConversation, let settings, let activeProject {
            MissionDossierCover(close: { showingMissionDossier = false }) {
                ProjectDashboardView(
                    project: activeProject,
                    projects: projects,
                    runtimeStatus: WorkspaceStatusSnapshot(runtime: projectRuntime),
                    autoContinueState: autoContinueViewState(for: activeProject, settings: settings),
                    conversations: conversations,
                    openTab: { tab in
                        showingMissionDossier = false
                        openTab(tab)
                    },
                    stopWorkspaceRun: {
                        projectRuntime.stopGenerating(context: modelContext)
                    },
                    approvePendingTool: {
                        projectRuntime.approvePendingTool(conversation: conversation, settings: settings, context: modelContext, project: activeProject)
                    },
                    rejectPendingTool: {
                        projectRuntime.rejectPendingTool(conversation: conversation, settings: settings, context: modelContext, project: activeProject)
                    },
                    setAutoContinueEnabled: setAutoContinueEnabled,
                    pauseAutoContinue: pauseAutoContinue,
                    cancelAutoContinue: cancelAutoContinue,
                    createProject: createProject,
                    selectProject: { project in
                        _ = selectProject(project)
                    },
                    updateProject: updateProject,
                    deleteProject: deleteProject,
                    runProjectCommand: runProjectCommand,
                    draftProjectCommand: draftProjectCommand,
                    openArtifactLandscapeFullScreen: openArtifactLandscapeFullScreen,
                    isVisibleForFrameProfiling: false
                )
            }
        }
    }

    @ViewBuilder
    private func terminalConsoleCover(for focus: TerminalConsoleFocusRequest) -> some View {
        if let activeProject {
            TerminalConsoleView(
                runtime: runtime,
                project: activeProject,
                openChat: {
                    terminalFocus = nil
                    openTab(.chat)
                },
                initialFocus: focus,
                close: {
                    terminalFocus = nil
                }
            )
        }
    }

    private func createConversation() {
        clearInactiveRuntimeForConversationSwitch()
        let previousSelectedConversationID = selectedConversationID
        let conversation = Conversation(title: makeConversationTitle(), project: nil)
        modelContext.insert(conversation)
        selectedConversationID = conversation.id
        optimisticSelectedConversation = conversation
        ProjectEventRecorder.record(
            project: nil,
            kind: .conversationStarted,
            title: "Conversation started",
            detail: conversation.title,
            severity: .info,
            sourceType: .conversation,
            sourceID: conversation.id,
            context: modelContext
        )
        guard saveRootContext("Could not create a new chat.") else {
            selectedConversationID = previousSelectedConversationID
            optimisticSelectedConversation = nil
            return
        }
        persistedSelectedConversationID = ""
        runtime.switchWorkspace(to: "Default")
        selectedTab = .chat
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    private func preferredGeneralConversation() -> Conversation? {
        ChatProjectSeparation.preferredGeneralConversation(
            from: conversations,
            selectedID: selectedConversationID,
            persistedIDString: persistedSelectedConversationID
        )
    }

    private func runtimeWorkspaceName(for activeProject: Project) -> String {
        if selectedTab == .chat {
            guard let chatProject = selectedConversation?.project else { return "Default" }
            return SandboxWorkspace.sanitizedWorkspaceName(chatProject.workspaceName)
        }
        return SandboxWorkspace.sanitizedWorkspaceName(activeProject.workspaceName)
    }

    private func syncRuntimeWorkspaceForCurrentSurface(activeProject: Project) {
        runtime.switchWorkspace(to: runtimeWorkspaceName(for: activeProject))
        if !projectRuntime.isWorking, projectRuntime.pendingTool == nil {
            projectRuntime.switchWorkspace(to: SandboxWorkspace.sanitizedWorkspaceName(activeProject.workspaceName))
        }
    }

    private func setConversationProjectScope(_ conversation: Conversation, _ project: Project?) {
        if runtime.isWorking || runtime.pendingTool != nil {
            runtime.presentToast("Pause or finish the active run before changing chat scope.", tone: .info)
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            return
        }

        let now = Date()
        conversation.project = project
        conversation.updatedAt = now
        if let project {
            project.lastActivityAt = now
            project.updatedAt = now
            settings?.activeProjectID = project.id
            settings?.activeWorkspaceName = SandboxWorkspace.sanitizedWorkspaceName(project.workspaceName)
            settings?.updatedAt = now
            ProjectEventRecorder.record(
                project: project,
                kind: .projectSelected,
                title: "Chat scope selected",
                detail: "\(conversation.title) will use \(project.name).",
                severity: .info,
                sourceType: .conversation,
                sourceID: conversation.id,
                context: modelContext,
                now: now
            )
        }

        guard saveRootContext("Could not change chat scope.") else { return }
        rootPrompt = ""
        rootPromptRevision += 1
        runtime.switchWorkspace(to: project.map { SandboxWorkspace.sanitizedWorkspaceName($0.workspaceName) } ?? "Default")
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    private func createProject(_ intake: ProjectIntakeDraft = .empty) {
        clearInactiveRuntimeForConversationSwitch()
        let generalConversation = preferredGeneralConversation()
        let now = Date()
        let ordinal = nextProjectOrdinal()
        let fallbackName = "Project \(ordinal)"
        let intakePrompt = intake.seedPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let seedPrompt = intakePrompt.isEmpty ? ProjectNamingEngine.identitySeed(from: selectedConversation) : intakePrompt
        let workingTitle = intake.workingTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let suggestedIdentity = seedPrompt.flatMap {
            ProjectNamingEngine.suggestedIdentity(
                prompt: $0,
                currentProjectName: fallbackName,
                currentMission: intake.missionText,
                existingProjectNames: Set(projects.map(\.name))
            )
        }
        let projectName = uniqueProjectName(
            suggestedIdentity?.name ?? (workingTitle.isEmpty ? fallbackName : workingTitle)
        )
        let workspaceName = SandboxWorkspace.sanitizedWorkspaceName(projectName)
        let project = Project(
            name: projectName,
            mission: intake.isEmpty ? (suggestedIdentity?.mission ?? "Plan, build, and verify one focused outcome.") : intake.missionText,
            workspaceName: workspaceName,
            now: now
        )
        project.nextStep = intake.isEmpty ? "Send the first project request." : intake.firstNextStep
        modelContext.insert(project)
        ProjectEventRecorder.record(
            project: project,
            kind: .projectCreated,
            title: intake.isEmpty ? "Project created" : "Project brief captured",
            detail: intake.isEmpty ? "\(projectName) is ready with its own workspace and mission history." : intake.seedPrompt,
            severity: .success,
            sourceType: .system,
            context: modelContext,
            now: now
        )
        ProjectEventRecorder.record(
            project: project,
            kind: .projectSelected,
            title: "Project selected",
            detail: "\(projectName) is now active in \(workspaceName).",
            severity: .info,
            sourceType: .system,
            context: modelContext,
            now: now
        )
        if !intake.isEmpty {
            ProjectEventRecorder.record(
                project: project,
                kind: .agentPlanCreated,
                title: "Intake plan ready",
                detail: intake.initialTaskPreview,
                severity: .info,
                sourceType: .system,
                metadata: [
                    "projectKind": intake.projectKind,
                    "platform": intake.platform,
                    "taskCount": "\(intake.initialAgentTasks.count)"
                ],
                context: modelContext,
                now: now.addingTimeInterval(0.001)
            )
        }
        let conversation = Conversation(title: projectName, project: project)
        modelContext.insert(conversation)
        ProjectEventRecorder.record(
            project: project,
            kind: .conversationStarted,
            title: "Conversation started",
            detail: conversation.title,
            severity: .info,
            sourceType: .conversation,
            sourceID: conversation.id,
            context: modelContext,
            now: now
        )
        settings?.activeProjectID = project.id
        settings?.activeWorkspaceName = workspaceName
        settings?.updatedAt = now
        guard saveRootContext("Could not create a new project.") else { return }
        selectedConversationID = generalConversation?.id ?? conversation.id
        if let generalConversation {
            persistedSelectedConversationID = LaunchConversationSelection.isLaunchRestorable(generalConversation)
                ? generalConversation.id.uuidString
                : ""
        } else {
            persistedSelectedConversationID = ""
        }
        rootPrompt = ""
        rootPromptRevision += 1
        landscapeGameArtifact = nil
        runtime.switchWorkspace(to: workspaceName)
        selectedTab = .project
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    private func uniqueProjectName(_ baseName: String) -> String {
        let trimmed = baseName.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = trimmed.isEmpty ? "Project \(nextProjectOrdinal())" : trimmed
        let existing = Set(projects.map { $0.name.lowercased() })
        if !existing.contains(base.lowercased()) { return base }
        for index in 2...99 {
            let candidate = "\(base) \(index)"
            if !existing.contains(candidate.lowercased()) { return candidate }
        }
        return "\(base) \(UUID().uuidString.prefix(4))"
    }

    private func nextProjectOrdinal() -> Int {
        let existingNames = Set(projects.map(\.name))
        var candidate = max(projects.count + 1, 2)
        while existingNames.contains("Mission Draft \(candidate)") || existingNames.contains("Project \(candidate)") {
            candidate += 1
        }
        return candidate
    }

    private func updateProject(_ project: Project, draft: ProjectEditDraft) {
        let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let mission = draft.mission.trimmingCharacters(in: .whitespacesAndNewlines)
        let workspaceName = SandboxWorkspace.sanitizedWorkspaceName(draft.workspaceName)
        guard !name.isEmpty, !mission.isEmpty, !workspaceName.isEmpty else {
            runtime.presentToast("Project name, mission, and workspace are required.", tone: .error)
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            return
        }

        let now = Date()
        let oldName = project.name
        project.name = uniqueProjectNameForEdit(name, editing: project)
        project.mission = mission
        project.workspaceName = workspaceName
        project.nextStep = draft.nextStep.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Choose the next concrete project task."
            : draft.nextStep.trimmingCharacters(in: .whitespacesAndNewlines)
        project.blocker = draft.blocker.trimmingCharacters(in: .whitespacesAndNewlines)
        project.status = draft.status
        project.updatedAt = now
        project.lastActivityAt = now

        if settings?.activeProjectID == project.id {
            settings?.activeWorkspaceName = workspaceName
            settings?.updatedAt = now
        }
        for conversation in mergedProjectConversations(for: project)
            where conversation.title == oldName || ProjectNamingEngine.isGenericName(conversation.title) {
            conversation.title = project.name
            conversation.updatedAt = now
        }
        ProjectEventRecorder.record(
            project: project,
            kind: .projectRenamed,
            title: "Project updated",
            detail: "\(oldName) -> \(project.name)",
            severity: .info,
            sourceType: .settings,
            context: modelContext,
            now: now
        )
        guard saveRootContext("Could not update project.") else { return }
        if settings?.activeProjectID == project.id {
            runtime.switchWorkspace(to: workspaceName)
            if !projectRuntime.isWorking, projectRuntime.pendingTool == nil {
                projectRuntime.switchWorkspace(to: workspaceName)
            }
        }
        runtime.presentToast("Project updated.", tone: .success)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    private func uniqueProjectNameForEdit(_ baseName: String, editing project: Project) -> String {
        let trimmed = baseName.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = trimmed.isEmpty ? project.name : trimmed
        let existing = Set(projects.filter { $0.id != project.id }.map { $0.name.lowercased() })
        if !existing.contains(base.lowercased()) { return base }
        for index in 2...99 {
            let candidate = "\(base) \(index)"
            if !existing.contains(candidate.lowercased()) { return candidate }
        }
        return "\(base) \(UUID().uuidString.prefix(4))"
    }

    private func deleteProject(_ project: Project) {
        if projectRuntime.isWorking || projectRuntime.pendingTool != nil {
            runtime.presentToast("Pause or finish the active run before deleting a project.", tone: .info)
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            return
        }

        clearInactiveRuntimeForConversationSwitch()
        let now = Date()
        let deletingActiveProject = settings?.activeProjectID == project.id || activeProject?.id == project.id
        let fallbackProject = projects
            .filter { $0.id != project.id }
            .sorted { lhs, rhs in
                if lhs.lastActivityAt != rhs.lastActivityAt { return lhs.lastActivityAt > rhs.lastActivityAt }
                return lhs.createdAt < rhs.createdAt
            }
            .first ?? {
                let replacement = Project(
                    name: ProjectBootstrap.defaultProjectName,
                    mission: "Build and verify useful work in NovaForge.",
                    workspaceName: "Default",
                    now: now
                )
                modelContext.insert(replacement)
                ProjectEventRecorder.record(
                    project: replacement,
                    kind: .projectCreated,
                    title: "Fallback project created",
                    detail: "NovaForge kept a safe project available after deletion.",
                    severity: .success,
                    sourceType: .system,
                    context: modelContext,
                    now: now
                )
                return replacement
            }()

        let deletedName = project.name
        modelContext.delete(project)

        if deletingActiveProject {
            settings?.activeProjectID = fallbackProject.id
            settings?.activeWorkspaceName = SandboxWorkspace.sanitizedWorkspaceName(fallbackProject.workspaceName)
            settings?.updatedAt = now
            selectedConversationID = preferredGeneralConversation()?.id ?? projectConversation(for: fallbackProject, now: now).id
        }

        guard saveRootContext("Could not delete project.") else { return }
        if deletingActiveProject {
            let fallbackWorkspace = SandboxWorkspace.sanitizedWorkspaceName(fallbackProject.workspaceName)
            runtime.switchWorkspace(to: fallbackWorkspace)
            if !projectRuntime.isWorking, projectRuntime.pendingTool == nil {
                projectRuntime.switchWorkspace(to: fallbackWorkspace)
            }
            selectedTab = .project
        }
        runtime.presentToast("Deleted \(deletedName).", tone: .success)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    @discardableResult
    private func selectProject(_ project: Project) -> Bool {
        if activeProject?.id != project.id, projectRuntime.isWorking || projectRuntime.pendingTool != nil {
            runtime.presentToast("Pause or finish the active run before switching projects.", tone: .info)
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            return false
        }
        clearInactiveRuntimeForConversationSwitch()
        let shouldPreserveGeneralChat = selectedConversation?.project == nil
        let now = Date()
        let previousProjectID = settings?.activeProjectID
        let safeWorkspaceName = SandboxWorkspace.sanitizedWorkspaceName(project.workspaceName)
        let conversation = projectConversation(for: project, now: now)
        project.lastActivityAt = now
        project.updatedAt = now
        if previousProjectID != project.id {
            ProjectEventRecorder.record(
                project: project,
                kind: .projectSelected,
                title: "Project selected",
                detail: "\(project.name) is active in \(safeWorkspaceName).",
                severity: .info,
                sourceType: .system,
                context: modelContext,
                now: now
            )
        }
        do {
            let persistedWorkspaceName = try AppRootPersistence.persistActiveProjectSelection(
                project,
                settings: settings,
                now: now,
                save: { try modelContext.save() }
            )
            if !shouldPreserveGeneralChat {
                selectedConversationID = conversation.id
            }
            runtime.switchWorkspace(to: persistedWorkspaceName)
            if !projectRuntime.isWorking, projectRuntime.pendingTool == nil {
                projectRuntime.switchWorkspace(to: persistedWorkspaceName)
            }
        } catch {
            modelContext.rollback()
            showRootSaveFailure("Could not switch projects.", error)
            return false
        }
        if shouldPreserveGeneralChat,
           let selected = selectedConversation,
           LaunchConversationSelection.isLaunchRestorable(selected) {
            persistedSelectedConversationID = selected.id.uuidString
        } else {
            persistedSelectedConversationID = ""
        }
        rootPrompt = ""
        rootPromptRevision += 1
        landscapeGameArtifact = nil
        selectedTab = .project
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        return true
    }

    private func continueProject(_ project: Project) {
        runProjectCommand(project, intent: .continueMission, operatorNote: "")
    }

    private func runProjectCommand(_ project: Project, intent: ProjectCommandIntent, operatorNote: String) {
        guard pendingProjectRunDispatchID != project.id else { return }
        pendingProjectRunDispatchID = project.id
        selectedTab = .project
        Task { @MainActor in
            await Task.yield()
            queueProjectCommand(project, intent: intent, operatorNote: operatorNote, shouldRunImmediately: true)
            if pendingProjectRunDispatchID == project.id {
                pendingProjectRunDispatchID = nil
            }
        }
    }

    private func draftProjectCommand(_ project: Project, intent: ProjectCommandIntent, operatorNote: String) {
        queueProjectCommand(project, intent: intent, operatorNote: operatorNote, shouldRunImmediately: false)
    }

    private func queueProjectCommand(
        _ project: Project,
        intent: ProjectCommandIntent,
        operatorNote: String,
        shouldRunImmediately: Bool
    ) {
        if activeProject?.id != project.id, projectRuntime.isWorking || projectRuntime.pendingTool != nil {
            runtime.presentToast("Pause or finish the active run before switching projects.", tone: .info)
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            return
        }
        if shouldRunImmediately, projectRuntime.isWorking || projectRuntime.pendingTool != nil {
            runtime.presentToast("Finish the current run before starting another project command.", tone: .info)
            selectedTab = .project
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            return
        }

        if activeProject?.id != project.id {
            guard selectProject(project) else { return }
        }
        guard let settings else { return }
        let now = Date()
        let conversation = projectConversation(for: project, now: now)
        applyProjectIdentitySuggestionIfNeeded(to: project, conversation: conversation)
        let summary = makeProjectSummary(for: project)
        let instruction = ProjectContinuationInstructionBuilder.makeInstruction(
            project: project,
            summary: summary,
            intent: intent,
            operatorNote: operatorNote
        )
        if shouldRunImmediately {
            ProjectOSRunLedger.startRun(
                project: project,
                summary: summary,
                intent: intent,
                operatorNote: operatorNote,
                sourceConversationID: conversation.id,
                origin: .manual,
                context: modelContext,
                now: now
            )
            projectRuntime.primeProjectRunProgress(project: project, summary: summary, intent: intent, operatorNote: operatorNote)
        }
        ProjectEventRecorder.record(
            project: project,
            kind: shouldRunImmediately ? .conversationContinued : .promptQueued,
            title: shouldRunImmediately ? "Agent command started" : "Project command drafted",
            detail: "\(intent.displayName). Next: \(summary.nextStep)",
            severity: .info,
            sourceType: .conversation,
            sourceID: conversation.id,
            context: modelContext,
            now: now
        )
        if shouldRunImmediately {
            ProjectEventRecorder.record(
                project: project,
                kind: .agentPlanCreated,
                title: "Agent run plan",
                detail: summary.nextStep,
                severity: .running,
                sourceType: .conversation,
                sourceID: conversation.id,
                metadata: [
                    "intent": intent.rawValue,
                    "proofRequirement": summary.missionContract.proofRequirement
                ],
                context: modelContext,
                now: now.addingTimeInterval(0.001)
            )
            ProjectEventRecorder.recordMissionCheckpoint(
                project: project,
                contract: summary.missionContract,
                trigger: "project-run-start",
                sourceType: .conversation,
                sourceID: conversation.id,
                context: modelContext,
                now: now.addingTimeInterval(0.002)
            )
        }
        guard saveRootContext("Could not queue the project command.") else {
            if shouldRunImmediately {
                projectRuntime.clearPrimedProjectRunProgress()
            }
            return
        }
        preserveGeneralChatSelection()
        selectedTab = .project
        rootPrompt = ""
        rootPromptRevision += 1
        if shouldRunImmediately {
            projectRuntime.send(
                prompt: instruction,
                conversation: conversation,
                settings: settings,
                context: modelContext,
                project: project,
                visiblePrompt: projectExecutionTranscriptLine(project: project, summary: summary, intent: intent)
            )
        } else {
            runtime.presentToast("Project command drafted in the Project timeline.", tone: .success)
        }
    }

    private func projectExecutionTranscriptLine(
        project: Project,
        summary: ProjectMissionSummary,
        intent: ProjectCommandIntent
    ) -> String {
        "ProjectOS run: \(intent.displayName) for \(project.name). Next: \(summary.nextStep)"
    }

    private func preserveGeneralChatSelection() {
        if let selectedConversation,
           selectedConversation.project == nil {
            persistedSelectedConversationID = LaunchConversationSelection.isLaunchRestorable(selectedConversation)
                ? selectedConversation.id.uuidString
                : ""
            return
        }
        if let general = preferredGeneralConversation() {
            selectedConversationID = general.id
            persistedSelectedConversationID = LaunchConversationSelection.isLaunchRestorable(general)
                ? general.id.uuidString
                : ""
        } else {
            selectedConversationID = nil
            persistedSelectedConversationID = ""
        }
    }

    private func applyProjectIdentitySuggestionIfNeeded(to project: Project, conversation: Conversation) {
        guard ProjectNamingEngine.shouldRename(project),
              let seedPrompt = ProjectNamingEngine.identitySeed(from: conversation) else { return }
        let existingNames = Set(projects.filter { $0.id != project.id }.map(\.name))
        guard let suggestion = ProjectNamingEngine.suggestedIdentity(
            prompt: seedPrompt,
            currentProjectName: project.name,
            currentMission: project.mission,
            existingProjectNames: existingNames
        ) else { return }

        let previousName = project.name
        project.name = suggestion.name
        if !suggestion.mission.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            project.mission = suggestion.mission
        }
        if conversation.title == previousName ||
            conversation.title == LaunchConversationSelection.safeStartTitle ||
            ProjectNamingEngine.isGenericName(conversation.title) {
            conversation.title = suggestion.name
        }
        ProjectEventRecorder.record(
            project: project,
            kind: .projectRenamed,
            title: "Project renamed",
            detail: "\(previousName) -> \(suggestion.name)",
            severity: .info,
            sourceType: .system,
            context: modelContext
        )
    }

    private func makeProjectSummary(for project: Project) -> ProjectMissionSummary {
        let signpostID = AgentPerformance.begin("Project Summary Build")
        defer {
            AgentPerformance.end("Project Summary Build", id: signpostID)
        }
        return ProjectMissionSummarizer.summarize(
            project: project,
            conversations: mergedProjectConversations(for: project),
            toolRuns: project.toolRuns,
            terminalCommands: project.terminalCommands,
            artifacts: project.artifacts,
            fileChanges: project.fileChanges,
            events: project.events
        )
    }

    private func autoContinueViewState(for project: Project, settings: AgentSettings) -> ProjectAutoContinueViewState {
        if autoContinueCountdownProjectID == project.id {
            return ProjectAutoContinueViewState(
                isEnabled: project.autoContinueEnabled,
                isPaused: project.autoContinuePaused,
                isCountingDown: true,
                remainingSeconds: max(autoContinueRemainingSeconds, 0),
                state: .countdown,
                title: autoContinueCountdownTitle.isEmpty ? "Auto-continue ready" : autoContinueCountdownTitle,
                detail: autoContinueCountdownDetail.isEmpty ? project.nextStep : autoContinueCountdownDetail
            )
        }

        guard project.autoContinueEnabled else { return .disabled }
        let evaluation = autoContinueEvaluation(for: project, settings: settings)
        let state: ProjectAutoContinueState = {
            if project.autoContinuePaused { return .paused }
            switch evaluation.action {
            case .schedule:
                return .idle
            case .stop:
                return .blocked
            case .waiting:
                return project.autoContinueState == .started ? .started : .idle
            case .disabled:
                return .idle
            }
        }()
        return ProjectAutoContinueViewState(
            isEnabled: true,
            isPaused: project.autoContinuePaused,
            isCountingDown: false,
            remainingSeconds: 0,
            state: state,
            title: project.autoContinueDecision?.isEmpty == false ? state.displayName : evaluation.title,
            detail: project.autoContinueDecision?.isEmpty == false ? project.autoContinueDecision! : evaluation.detail
        )
    }

    private func autoContinueEvaluation(for project: Project, settings: AgentSettings) -> ProjectAutoContinueEvaluation {
        let summary = makeProjectSummary(for: project)
        return ProjectAutoContinuePolicy.evaluate(
            project: project,
            summary: summary,
            settings: settings,
            runtimeIsWorking: projectRuntime.isWorking,
            hasPendingRuntimeApproval: projectRuntime.pendingTool != nil,
            runCompleted: projectRuntime.runState == .completed,
            runFailedOrPaused: runtimeRunFailedOrPaused,
            hasUsableProviderCredential: projectRuntime.hasUsableProviderCredential(settings: settings),
            latestRunEventID: latestRunCompletedEvent(for: project)?.id.uuidString
        )
    }

    private var runtimeRunFailedOrPaused: Bool {
        if projectRuntime.wasInterrupted || projectRuntime.lastError != nil || projectRuntime.runState == .cancelled {
            return true
        }
        if case .failed = projectRuntime.runState {
            return true
        }
        return false
    }

    private func latestRunCompletedEvent(for project: Project) -> ProjectEvent? {
        project.events
            .filter { $0.kind == .runCompleted }
            .sorted { lhs, rhs in
                if lhs.createdAt != rhs.createdAt { return lhs.createdAt > rhs.createdAt }
                return lhs.id.uuidString < rhs.id.uuidString
            }
            .first
    }

    private func reconcileAutoContinue() {
        guard let activeProject, let settings else {
            cancelAutoContinueCountdown(clearProjectState: false)
            return
        }
        let evaluation = autoContinueEvaluation(for: activeProject, settings: settings)
        switch evaluation.action {
        case .schedule:
            scheduleAutoContinue(project: activeProject, settings: settings, evaluation: evaluation)
        case .stop:
            stopAutoContinue(project: activeProject, evaluation: evaluation)
        case .disabled:
            if autoContinueCountdownProjectID == activeProject.id {
                cancelAutoContinueCountdown(clearProjectState: false)
            }
        case .waiting:
            break
        }
    }

    private func scheduleAutoContinue(
        project: Project,
        settings: AgentSettings,
        evaluation: ProjectAutoContinueEvaluation
    ) {
        guard let sourceEventID = evaluation.sourceEventID else { return }
        if autoContinueCountdownProjectID == project.id,
           autoContinueCountdownSourceEventID == sourceEventID {
            return
        }

        autoContinueCountdownTask?.cancel()
        let now = Date()
        project.autoContinuePaused = false
        project.autoContinueState = .countdown
        project.autoContinueSourceEventIDString = sourceEventID
        project.autoContinueDecision = evaluation.detail
        project.autoContinueUpdatedAt = now
        ProjectEventRecorder.record(
            project: project,
            kind: .autoContinueScheduled,
            title: "Auto-continue scheduled",
            detail: evaluation.detail,
            severity: .info,
            sourceType: .system,
            metadata: [
                "sourceRunEvent": sourceEventID,
                "intent": evaluation.intent.rawValue
            ],
            context: modelContext,
            now: now
        )
        guard saveRootContext("Could not schedule auto-continue.") else { return }

        autoContinueCountdownProjectID = project.id
        autoContinueCountdownSourceEventID = sourceEventID
        autoContinueRemainingSeconds = ProjectAutoContinuePolicy.countdownSeconds
        autoContinueCountdownTitle = evaluation.title
        autoContinueCountdownDetail = evaluation.detail

        autoContinueCountdownTask = Task { @MainActor in
            for remaining in stride(from: ProjectAutoContinuePolicy.countdownSeconds, through: 1, by: -1) {
                guard !Task.isCancelled else { return }
                autoContinueRemainingSeconds = remaining
                try? await Task.sleep(for: .seconds(1))
            }
            guard !Task.isCancelled else { return }
            autoContinueRemainingSeconds = 0
            autoContinueCountdownTask = nil
            startAutoContinuedRun(projectID: project.id, sourceEventID: sourceEventID)
        }
    }

    private func setAutoContinueEnabled(_ project: Project, _ enabled: Bool) {
        autoContinueCountdownTask?.cancel()
        autoContinueCountdownTask = nil
        if autoContinueCountdownProjectID == project.id {
            clearAutoContinueCountdownState()
        }
        let now = Date()
        project.autoContinueEnabled = enabled
        project.autoContinuePaused = false
        project.autoContinueState = enabled ? .idle : .idle
        project.autoContinueDecision = enabled ? "Auto-continue will wait for a clean completed run." : "Auto-continue is off for this project."
        project.autoContinueUpdatedAt = now
        if !enabled {
            project.autoContinueSourceEventIDString = nil
        }
        ProjectEventRecorder.record(
            project: project,
            kind: enabled ? .autoContinueEnabled : .autoContinueDisabled,
            title: enabled ? "Auto-continue enabled" : "Auto-continue disabled",
            detail: project.autoContinueDecision ?? "",
            severity: .info,
            sourceType: .settings,
            context: modelContext,
            now: now
        )
        guard saveRootContext(enabled ? "Could not enable auto-continue." : "Could not disable auto-continue.") else { return }
        if enabled {
            reconcileAutoContinue()
        }
    }

    private func pauseAutoContinue(_ project: Project) {
        cancelAutoContinueCountdown(clearProjectState: false)
        let now = Date()
        project.autoContinuePaused = true
        project.autoContinueState = .paused
        project.autoContinueDecision = "Paused by user before the next automatic step."
        project.autoContinueUpdatedAt = now
        ProjectEventRecorder.record(
            project: project,
            kind: .autoContinuePaused,
            title: "Auto-continue paused",
            detail: project.autoContinueDecision ?? "",
            severity: .warning,
            sourceType: .system,
            context: modelContext,
            now: now
        )
        _ = saveRootContext("Could not pause auto-continue.")
    }

    private func cancelAutoContinue(_ project: Project) {
        setAutoContinueEnabled(project, false)
    }

    private func stopAutoContinue(project: Project, evaluation: ProjectAutoContinueEvaluation) {
        if autoContinueCountdownProjectID == project.id {
            cancelAutoContinueCountdown(clearProjectState: false)
        }
        let alreadyStopped = project.autoContinueState == .blocked &&
            project.autoContinueDecision == evaluation.detail &&
            project.autoContinueSourceEventIDString == evaluation.sourceEventID
        guard project.autoContinueEnabled, !alreadyStopped else { return }

        let now = Date()
        project.autoContinueState = .blocked
        project.autoContinueDecision = evaluation.detail
        project.autoContinueSourceEventIDString = evaluation.sourceEventID
        project.autoContinueUpdatedAt = now
        ProjectEventRecorder.record(
            project: project,
            kind: .autoContinuePaused,
            title: evaluation.title,
            detail: evaluation.detail,
            severity: .warning,
            sourceType: .system,
            metadata: evaluation.sourceEventID.map { ["sourceRunEvent": $0] } ?? [:],
            context: modelContext,
            now: now
        )
        _ = saveRootContext("Could not save auto-continue state.")
    }

    private func cancelAutoContinueCountdown(clearProjectState: Bool) {
        autoContinueCountdownTask?.cancel()
        autoContinueCountdownTask = nil
        if clearProjectState,
           let projectID = autoContinueCountdownProjectID,
           let project = projects.first(where: { $0.id == projectID }) {
            project.autoContinueState = .idle
            project.autoContinueDecision = nil
            project.autoContinueUpdatedAt = Date()
            _ = saveRootContext("Could not clear auto-continue countdown.")
        }
        clearAutoContinueCountdownState()
    }

    private func clearAutoContinueCountdownState() {
        autoContinueCountdownProjectID = nil
        autoContinueCountdownSourceEventID = nil
        autoContinueRemainingSeconds = 0
        autoContinueCountdownTitle = ""
        autoContinueCountdownDetail = ""
    }

    private func startAutoContinuedRun(projectID: UUID, sourceEventID: String) {
        defer {
            clearAutoContinueCountdownState()
        }
        guard let project = projects.first(where: { $0.id == projectID }),
              let settings else { return }
        guard activeProject?.id == projectID else {
            project.autoContinuePaused = true
            project.autoContinueState = .paused
            project.autoContinueDecision = "Paused because another project became active before the countdown finished."
            project.autoContinueUpdatedAt = Date()
            ProjectEventRecorder.record(
                project: project,
                kind: .autoContinuePaused,
                title: "Auto-continue paused",
                detail: project.autoContinueDecision ?? "",
                severity: .warning,
                sourceType: .system,
                context: modelContext
            )
            _ = saveRootContext("Could not pause auto-continue.")
            return
        }

        let evaluation = autoContinueEvaluation(for: project, settings: settings)
        guard evaluation.action == .schedule,
              evaluation.sourceEventID == sourceEventID else {
            stopAutoContinue(project: project, evaluation: evaluation)
            return
        }
        guard !projectRuntime.isWorking, projectRuntime.pendingTool == nil else { return }

        let now = Date()
        let conversation = autoContinueConversation(for: project, sourceEventID: sourceEventID, now: now)
        let summary = makeProjectSummary(for: project)
        let note = "Auto-continued after a \(ProjectAutoContinuePolicy.countdownSeconds)-second pause. \(evaluation.detail)"
        let instruction = ProjectContinuationInstructionBuilder.makeInstruction(
            project: project,
            summary: summary,
            intent: evaluation.intent,
            operatorNote: note
        )
        ProjectOSRunLedger.startRun(
            project: project,
            summary: summary,
            intent: evaluation.intent,
            operatorNote: note,
            sourceConversationID: conversation.id,
            origin: .autoContinued,
            context: modelContext,
            now: now
        )
        project.autoContinueState = .started
        project.autoContinueSourceEventIDString = sourceEventID
        project.autoContinueDecision = "Started \(evaluation.intent.displayName): \(summary.nextStep)"
        project.autoContinueUpdatedAt = now
        ProjectEventRecorder.record(
            project: project,
            kind: .autoContinueStarted,
            title: "Auto-continued run started",
            detail: project.autoContinueDecision ?? "",
            severity: .running,
            sourceType: .conversation,
            sourceID: conversation.id,
            metadata: [
                "sourceRunEvent": sourceEventID,
                "intent": evaluation.intent.rawValue
            ],
            context: modelContext,
            now: now
        )
        guard saveRootContext("Could not start auto-continued run.") else { return }

        preserveGeneralChatSelection()
        selectedTab = .project
        rootPrompt = ""
        rootPromptRevision += 1
        projectRuntime.primeProjectRunProgress(project: project, summary: summary, intent: evaluation.intent, operatorNote: note)
        projectRuntime.send(
            prompt: instruction,
            conversation: conversation,
            settings: settings,
            context: modelContext,
            project: project,
            origin: .autoContinued,
            visiblePrompt: projectExecutionTranscriptLine(project: project, summary: summary, intent: evaluation.intent)
        )
    }

    private func autoContinueConversation(for project: Project, sourceEventID: String, now: Date) -> Conversation {
        if let event = project.events.first(where: { $0.id.uuidString == sourceEventID }),
           let sourceIDString = event.sourceIDString,
           let sourceID = UUID(uuidString: sourceIDString),
           let conversation = (conversations + project.conversations).first(where: { $0.id == sourceID }) {
            return conversation
        }
        return projectConversation(for: project, now: now)
    }

    private func mergedProjectConversations(for project: Project) -> [Conversation] {
        var seenIDs = Set<UUID>()
        return (conversations + project.conversations).filter { conversation in
            guard conversation.project?.id == project.id else { return false }
            return seenIDs.insert(conversation.id).inserted
        }
    }

    private func projectConversation(for project: Project, now: Date) -> Conversation {
        var seenIDs = Set<UUID>()
        let candidates = (conversations + project.conversations)
            .filter { candidate in
                guard candidate.project?.id == project.id, !seenIDs.contains(candidate.id) else { return false }
                seenIDs.insert(candidate.id)
                return true
            }
        if let existingConversation = candidates
            .sorted(by: { lhs, rhs in
                if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
                return lhs.createdAt > rhs.createdAt
            })
            .first {
            return existingConversation
        }

        let conversation = Conversation(title: project.name, project: project)
        modelContext.insert(conversation)
        ProjectEventRecorder.record(
            project: project,
            kind: .conversationStarted,
            title: "Conversation started",
            detail: conversation.title,
            severity: .info,
            sourceType: .conversation,
            sourceID: conversation.id,
            context: modelContext,
            now: now
        )
        return conversation
    }

    private func selectConversation(_ conversation: Conversation) {
        clearInactiveRuntimeForConversationSwitch()
        if optimisticSelectedConversation?.id != conversation.id {
            optimisticSelectedConversation = nil
        }
        selectedConversationID = conversation.id
        if let project = conversation.project {
            let safeWorkspaceName = SandboxWorkspace.sanitizedWorkspaceName(project.workspaceName)
            let needsProjectSwitch = settings?.activeProjectID != project.id
            let needsWorkspaceRepair = settings?.activeWorkspaceName != safeWorkspaceName || project.workspaceName != safeWorkspaceName
            if needsProjectSwitch || needsWorkspaceRepair {
                do {
                    let persistedWorkspaceName = try AppRootPersistence.persistActiveProjectSelection(
                        project,
                        settings: settings,
                        save: { try modelContext.save() }
                    )
                    runtime.switchWorkspace(to: persistedWorkspaceName)
                    if !projectRuntime.isWorking, projectRuntime.pendingTool == nil {
                        projectRuntime.switchWorkspace(to: persistedWorkspaceName)
                    }
                } catch {
                    showRootSaveFailure("Could not switch projects for this chat.", error)
                }
            }
        } else {
            runtime.switchWorkspace(to: "Default")
        }
        if LaunchConversationSelection.isLaunchRestorable(conversation) {
            persistedSelectedConversationID = conversation.id.uuidString
        } else if persistedSelectedConversationID == conversation.id.uuidString {
            persistedSelectedConversationID = ""
        }
    }

    private func clearInactiveRuntimeForConversationSwitch() {
        guard !runtime.isWorking, runtime.pendingTool == nil else { return }
        guard runtime.lastError != nil ||
              runtime.wasInterrupted ||
              runtime.lastRunDuration != nil ||
              runtime.queuedPromptCount > 0 ||
              !runtime.currentArtifacts.isEmpty ||
              !runtime.traceEvents.isEmpty ||
              !runtime.liveStream.isEmpty else { return }
        runtime.clearCurrentRunState(keepLastFailure: false)
    }

    private func reconcileLaunchSelection() {
        guard let selected = selectedConversation else { return }
        if selectedConversationID == nil {
            selectedConversationID = selected.id
        }
        persistSelectedConversationIfSafe()
    }

    private func persistSelectedConversationIfSafe() {
        guard let selected = selectedConversation else {
            persistedSelectedConversationID = ""
            return
        }
        if LaunchConversationSelection.isLaunchRestorable(selected) {
            persistedSelectedConversationID = selected.id.uuidString
        } else if persistedSelectedConversationID == selected.id.uuidString ||
                    UUID(uuidString: persistedSelectedConversationID) != nil {
            persistedSelectedConversationID = ""
        }
    }

    private func repairActiveWorkspaceNameChange(_ workspaceName: String?) {
        guard let workspaceName else { return }
        do {
            let safeName = try AppRootPersistence.repairActiveWorkspaceName(
                workspaceName,
                settings: settings,
                save: { try modelContext.save() }
            )
            if let activeProject, activeProject.workspaceName != safeName {
                ProjectEventRecorder.record(
                    project: activeProject,
                    kind: .workspaceChanged,
                    title: "Workspace changed",
                    detail: safeName,
                    severity: .info,
                    sourceType: .workspace,
                    context: modelContext
                )
                do {
                    try FilesWorkspacePersistence.persistProjectWorkspaceSelection(
                        safeName,
                        project: activeProject,
                        settings: settings,
                        save: { try modelContext.save() }
                    )
                } catch {
                    modelContext.rollback()
                    showRootSaveFailure("Could not save the active project workspace.", error)
                    return
                }
            }
            runtime.switchWorkspace(to: safeName)
            if !projectRuntime.isWorking, projectRuntime.pendingTool == nil {
                projectRuntime.switchWorkspace(to: safeName)
            }
        } catch {
            showRootSaveFailure("Could not repair the active workspace name.", error)
        }
    }

    private func repairRootStaleModelSelection() {
        do {
            try AppRootPersistence.repairStaleModelSelection(
                settings: settings,
                save: { try modelContext.save() }
            )
        } catch {
            showRootSaveFailure("Could not repair the selected model.", error)
        }
    }

    private func repairActiveProjectIfNeeded() {
        guard let settings else { return }
        _ = ProjectBootstrap.ensureDefaultProject(in: modelContext, settings: settings)
        do {
            try modelContext.save()
        } catch {
            showRootSaveFailure("Could not prepare the active project.", error)
        }
    }

    private func repairRequiredLaunchRecords() {
        do {
            let result = try AppRootLaunchRepair.ensureLaunchRecords(
                in: modelContext,
                settings: settings,
                selectedConversation: selectedConversation
            )
            if selectedConversationID == nil {
                selectedConversationID = result.conversation.id
            }
            try modelContext.save()
        } catch {
            showRootSaveFailure("Could not repair NovaForge launch state.", error)
        }
    }

    @discardableResult
    private func saveRootContext(_ failureMessage: String) -> Bool {
        do {
            try modelContext.save()
            return true
        } catch {
            modelContext.rollback()
            showRootSaveFailure(failureMessage, error)
            return false
        }
    }

    private func showRootSaveFailure(_ failureMessage: String, _ error: Error) {
        rootError = "\(failureMessage) \(error.localizedDescription)"
        UINotificationFeedbackGenerator().notificationOccurred(.error)
    }

    private func startTabSwitch(from oldTab: AppTab, to newTab: AppTab) {
        guard oldTab != newTab else { return }
        tabSwitchStartedAt = Date()
        pendingTabSwitch = newTab
        AgentPerformance.event("Tab Switch Started")
        AgentPerformance.value("Tab Switch Source", oldTab.performanceIndex)
        AgentPerformance.value("Tab Switch Target", newTab.performanceIndex)
    }

    private func completeTabSwitch(to tab: AppTab) {
        guard pendingTabSwitch == tab, let startedAt = tabSwitchStartedAt else { return }
        let durationMilliseconds = max(0, Date().timeIntervalSince(startedAt) * 1_000)
        AgentPerformance.value("Tab Switch Duration ms", durationMilliseconds)
        AgentPerformance.event("Tab Switch Completed")
        pendingTabSwitch = nil
        tabSwitchStartedAt = nil
    }

    private func openTab(_ tab: AppTab) {
        AgentPerformance.event("Tab Switch Requested")
        selectedTab = tab
    }

    private func scheduleAutoTabSwitchProfileIfNeeded() {
        guard !didRunAutoTabSwitchProfile else { return }
        guard ProcessInfo.processInfo.arguments.contains("--auto-tab-switch-profile") else { return }
        didRunAutoTabSwitchProfile = true
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(1_600))
            guard !Task.isCancelled else { return }
            let sequence: [AppTab] = [.forge, .workspace, .history, .control, .forge, .workspace, .history, .forge]
            for tab in sequence {
                guard !Task.isCancelled else { return }
                openTab(tab)
                try? await Task.sleep(for: .milliseconds(520))
            }
        }
    }

    private var launchRecoveryPanel: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .center, spacing: 14) {
                ZStack {
                    Circle()
                        .fill(AgentPalette.cyan.opacity(0.18))
                    Circle()
                        .stroke(AgentPalette.cyan.opacity(0.35), lineWidth: 1)
                    Image(systemName: "wrench.and.screwdriver.fill")
                        .font(.system(size: 22, weight: .black))
                        .foregroundStyle(AgentPalette.cyan)
                }
                .frame(width: 54, height: 54)

                VStack(alignment: .leading, spacing: 5) {
                    Text("Repairing NovaForge")
                        .font(.system(size: 20, weight: .black, design: AgentPalette.interfaceFontDesign))
                        .foregroundStyle(AgentPalette.ink)
                    Text("Project OS is restoring its launch records.")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(AgentPalette.secondaryText)
                }
            }

            VStack(spacing: 10) {
                launchStatusRow(title: "Settings", isReady: settings != nil)
                launchStatusRow(title: "Project", isReady: activeProject != nil)
                launchStatusRow(title: "Conversation", isReady: selectedConversation != nil)
            }

            HStack(spacing: 10) {
                ProgressView()
                    .tint(AgentPalette.cyan)
                Button {
                    repairRequiredLaunchRecords()
                } label: {
                    Label("Repair Now", systemImage: "arrow.clockwise")
                        .font(.system(size: 12, weight: .black, design: AgentPalette.interfaceFontDesign))
                }
                .buttonStyle(.borderedProminent)
                .tint(AgentPalette.cyan)
            }
        }
        .padding(22)
        .frame(maxWidth: 360, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(AgentPalette.surface.opacity(0.94))
                .overlay(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .stroke(AgentPalette.border, lineWidth: 1)
                )
        )
        .shadow(color: AgentPalette.shadow, radius: 24, x: 0, y: 18)
        .padding(.horizontal, 22)
        .task {
            repairRequiredLaunchRecords()
        }
    }

    private func launchStatusRow(title: String, isReady: Bool) -> some View {
        HStack(spacing: 9) {
            Image(systemName: isReady ? "checkmark.circle.fill" : "circle.dashed")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(isReady ? AgentPalette.green : AgentPalette.tertiaryText)
            Text(title)
                .font(.system(size: 12, weight: .bold, design: AgentPalette.interfaceFontDesign))
                .foregroundStyle(AgentPalette.ink)
            Spacer()
            Text(isReady ? "Ready" : "Restoring")
                .font(.system(size: 10, weight: .black, design: AgentPalette.interfaceFontDesign))
                .foregroundStyle(isReady ? AgentPalette.green : AgentPalette.tertiaryText)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(AgentPalette.surfaceAlt.opacity(0.18), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    #if DEBUG || targetEnvironment(simulator)
    private func scheduleLiveTerminalRecordFixture(for project: Project) {
        didInjectLiveTerminalRecordFixture = true
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(1_500))
            installLiveTerminalRecordFixture(for: project)
            try? modelContext.save()
        }
    }

    private func installLiveTerminalRecordFixture(for project: Project) {
        let command = "pwd"
        let output = "/\nagent live terminal sync proof"
        let run = ToolRun(
            name: "run_command",
            argumentsJSON: jsonString(["command": command]),
            output: output,
            status: .completed,
            requiresApproval: false,
            isMutating: false,
            project: project
        )
        let completedAt = Date()
        run.createdAt = completedAt.addingTimeInterval(-0.18)
        run.completedAt = completedAt
        modelContext.insert(run)

        let record = TerminalCommandRecord(
            project: project,
            command: command,
            output: output,
            status: .completed,
            workspaceName: runtime.workspace.workspaceName,
            startedAt: run.createdAt,
            completedAt: completedAt,
            durationMs: completedAt.timeIntervalSince(run.createdAt) * 1000.0,
            sourceToolRunID: run.id
        )
        modelContext.insert(record)
        ProjectEventRecorder.record(
            project: project,
            kind: .terminalCommand,
            title: "Agent command completed",
            detail: command,
            severity: .success,
            sourceType: .terminalCommand,
            sourceID: record.id,
            metadata: [
                "command": command,
                "workspace": runtime.workspace.workspaceName,
                "toolRun": run.id.uuidString
            ],
            context: modelContext
        )
    }

    private func installPendingApprovalFixture(in conversation: Conversation) {
        let arguments = [
            "path": "approval-demo.html",
            "contents": "<html><body><h1>Approved by NovaForge</h1></body></html>"
        ]
        let argumentsJSON = (try? String(
            data: JSONSerialization.data(withJSONObject: arguments, options: [.sortedKeys]),
            encoding: .utf8
        )) ?? "{\"path\":\"approval-demo.html\"}"
        let call = APIToolCall(
            id: "approval-demo-write",
            type: "function",
            function: APIFunctionCall(name: "write_file", arguments: argumentsJSON)
        )
        let toolCallsJSON = (try? JSONEncoder().encode([call])).flatMap { String(data: $0, encoding: .utf8) }
        let user = ChatMessage(
            role: .user,
            content: "Create an approval demo file.",
            conversation: conversation
        )
        let assistant = ChatMessage(
            role: .assistant,
            content: "I need approval before writing the demo artifact.",
            toolCallsJSON: toolCallsJSON,
            conversation: conversation
        )
        conversation.appendMessages([user, assistant])
        modelContext.insert(user)
        modelContext.insert(assistant)

        let request = ToolRequest(id: call.id, name: call.function.name, arguments: arguments)
        let run = ToolRun(
            name: request.name,
            argumentsJSON: request.argumentsJSON,
            output: "Waiting for approval.",
            status: .pendingApproval,
            requiresApproval: true,
            isMutating: true,
            project: activeProject
        )
        modelContext.insert(run)
        conversation.project = conversation.project ?? activeProject
        ProjectEventRecorder.record(
            project: activeProject,
            kind: .toolApprovalRequested,
            title: "Approval demo waiting",
            detail: request.argumentsJSON,
            severity: .warning,
            sourceType: .toolRun,
            sourceID: run.id,
            context: modelContext
        )
        runtime.debugInstallPendingApproval(request: request, run: run)
        conversation.refreshMessageMetadata(updateTimestamp: Date())
    }

    private func installCompletedArtifactFixture(in conversation: Conversation) {
        let artifact = WorkspaceArtifact(path: "playable-game-dedupe-demo.html")
        let user = ChatMessage(
            role: .user,
            content: "Create a playable artifact and show me the result.",
            conversation: conversation
        )
        let assistant = ChatMessage(
            role: .assistant,
            content: "Playable game ready. Open the generated artifact from Run Control.",
            conversation: conversation
        )
        conversation.appendMessages([user, assistant])
        modelContext.insert(user)
        modelContext.insert(assistant)

        let arguments = [
            "path": artifact.path,
            "contents": "<html><body><h1>Artifact Dedupe Demo</h1></body></html>"
        ]
        let argumentsJSON = (try? String(
            data: JSONSerialization.data(withJSONObject: arguments, options: [.sortedKeys]),
            encoding: .utf8
        )) ?? "{\"path\":\"playable-game-dedupe-demo.html\"}"
        let run = ToolRun(
            name: "write_file",
            argumentsJSON: argumentsJSON,
            output: "Wrote \(artifact.path)",
            status: .completed,
            requiresApproval: false,
            isMutating: true,
            project: activeProject
        )
        run.completedAt = Date()
        modelContext.insert(run)
        conversation.project = conversation.project ?? activeProject
        ProjectEventRecorder.ensureArtifact(
            artifact,
            project: activeProject,
            sourceToolRunID: run.id,
            context: modelContext
        )
        runtime.debugInstallCompletedArtifact(artifact)
        conversation.refreshMessageMetadata(updateTimestamp: Date())
    }

    private func installLocalAgentBoundaryFixture(in conversation: Conversation) {
        let artifact = WorkspaceArtifact(path: "slither-arena.html")
        let html = """
        <!doctype html>
        <html lang="en">
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
          <title>Slither Arena</title>
          <style>
            html, body { margin: 0; min-height: 100%; background: #061018; color: #ecfeff; font-family: -apple-system, BlinkMacSystemFont, sans-serif; }
            body { display: grid; place-items: center; overflow: hidden; background: radial-gradient(circle at 30% 20%, #1dd8ff55, transparent 32%), linear-gradient(135deg, #061018, #10243a); }
            main { width: min(92vw, 900px); border: 1px solid #ffffff26; border-radius: 32px; padding: 32px; background: #ffffff12; box-shadow: 0 24px 80px #0009; }
            h1 { margin: 0 0 8px; font-size: clamp(44px, 10vw, 96px); letter-spacing: -.08em; }
            p { margin: 0; color: #aef8ff; font-weight: 800; }
            canvas { display: block; width: 100%; aspect-ratio: 16 / 9; margin-top: 24px; border-radius: 24px; background: linear-gradient(135deg, #0f5368, #123f88); }
          </style>
        </head>
        <body><main><h1>Slither Arena</h1><p>Playable game ready from deterministic native tool fixture.</p><canvas id="game"></canvas></main><script>
          const canvas = document.getElementById('game');
          const ctx = canvas.getContext('2d');
          function draw() {
            const rect = canvas.getBoundingClientRect();
            const scale = Math.max(1, window.devicePixelRatio || 1);
            canvas.width = Math.max(320, Math.floor(rect.width * scale));
            canvas.height = Math.max(180, Math.floor(rect.height * scale));
            ctx.setTransform(scale, 0, 0, scale, 0, 0);
            const w = canvas.width / scale, h = canvas.height / scale;
            const gradient = ctx.createLinearGradient(0, 0, w, h);
            gradient.addColorStop(0, '#21e6ff');
            gradient.addColorStop(0.45, '#2459ff');
            gradient.addColorStop(1, '#8affc1');
            ctx.fillStyle = gradient;
            ctx.fillRect(0, 0, w, h);
            ctx.globalAlpha = 0.22;
            ctx.strokeStyle = '#061018';
            ctx.lineWidth = 2;
            for (let x = 0; x < w; x += Math.max(34, w / 18)) { ctx.beginPath(); ctx.moveTo(x, 0); ctx.lineTo(x, h); ctx.stroke(); }
            for (let y = 0; y < h; y += Math.max(34, h / 10)) { ctx.beginPath(); ctx.moveTo(0, y); ctx.lineTo(w, y); ctx.stroke(); }
            ctx.globalAlpha = 1;
            ctx.lineCap = 'round';
            ctx.lineJoin = 'round';
            ctx.strokeStyle = '#f4ff7a';
            ctx.lineWidth = Math.max(18, Math.min(w, h) * 0.045);
            ctx.beginPath();
            for (let i = 0; i < 9; i++) {
              const x = w * (0.12 + i * 0.095);
              const y = h * (0.52 + Math.sin(i * 0.9) * 0.22);
              if (i === 0) ctx.moveTo(x, y); else ctx.lineTo(x, y);
            }
            ctx.stroke();
            ctx.fillStyle = '#061018';
            ctx.beginPath();
            ctx.arc(w * 0.90, h * 0.38, Math.max(20, h * 0.07), 0, Math.PI * 2);
            ctx.fill();
            ctx.fillStyle = '#ffffff';
            ctx.beginPath(); ctx.arc(w * 0.885, h * 0.365, 5, 0, Math.PI * 2); ctx.fill();
            ctx.beginPath(); ctx.arc(w * 0.918, h * 0.382, 5, 0, Math.PI * 2); ctx.fill();
          }
          window.addEventListener('resize', draw);
          window.visualViewport?.addEventListener('resize', draw);
          requestAnimationFrame(draw);
          setTimeout(draw, 250);
        </script></body>
        </html>
        """
        try? runtime.workspace.write(artifact.path, contents: html)

        let calls: [APIToolCall] = [
            APIToolCall(
                id: "debug-local-write",
                type: "function",
                function: APIFunctionCall(
                    name: "write_file",
                    arguments: jsonString([
                        "path": artifact.path,
                        "contents": html
                    ])
                )
            ),
            APIToolCall(
                id: "debug-local-validate",
                type: "function",
                function: APIFunctionCall(
                    name: "validate_html_file",
                    arguments: jsonString([
                        "path": artifact.path,
                        "profile": "game"
                    ])
                )
            ),
            APIToolCall(
                id: "debug-local-info",
                type: "function",
                function: APIFunctionCall(
                    name: "file_info",
                    arguments: jsonString(["path": artifact.path])
                )
            )
        ]
        let toolCallsJSON = (try? String(
            data: JSONEncoder().encode(calls),
            encoding: .utf8
        ))

        let user = ChatMessage(
            role: .user,
            content: "Make a slither game as an HTML file and run it.",
            conversation: conversation
        )
        let plan = ChatMessage(
            role: .assistant,
            content: "I’ll build and verify the game with native tools.",
            toolCallsJSON: toolCallsJSON,
            conversation: conversation
        )
        let writeResult = ChatMessage(
            role: .tool,
            content: "Wrote \(artifact.path)",
            toolCallID: calls[0].id,
            conversation: conversation
        )
        let validateResult = ChatMessage(
            role: .tool,
            content: "HTML validation passed for \(artifact.path)",
            toolCallID: calls[1].id,
            conversation: conversation
        )
        let infoResult = ChatMessage(
            role: .tool,
            content: "\(artifact.path) · \(html.count) bytes · text/html",
            toolCallID: calls[2].id,
            conversation: conversation
        )
        let final = ChatMessage(
            role: .assistant,
            content: "Playable game ready. Open slither-arena.html from Run Control.",
            conversation: conversation
        )
        conversation.appendMessages([user, plan, writeResult, validateResult, infoResult, final])
        [user, plan, writeResult, validateResult, infoResult, final].forEach(modelContext.insert)

        let run = ToolRun(
            name: "write_file",
            argumentsJSON: jsonString(["path": artifact.path, "contents": html]),
            output: "Wrote \(artifact.path)",
            status: .completed,
            requiresApproval: false,
            isMutating: true,
            project: activeProject
        )
        run.completedAt = Date()
        modelContext.insert(run)
        conversation.project = conversation.project ?? activeProject
        ProjectEventRecorder.ensureArtifact(
            artifact,
            project: activeProject,
            sourceToolRunID: run.id,
            context: modelContext
        )
        runtime.debugInstallCompletedLocalAgentBoundaryArtifact(artifact)
        conversation.refreshMessageMetadata(updateTimestamp: Date())
    }

    private func installCompletedWebPageArtifactFixture(in conversation: Conversation) {
        let artifact = WorkspaceArtifact(path: "cron-18-landing.html")
        let html = """
        <!doctype html>
        <html lang="en">
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
          <title>Robotics Launch Page</title>
          <style>
            body { margin: 0; min-height: 100svh; display: grid; place-items: center; background: linear-gradient(135deg, #071018, #173047); color: white; font-family: -apple-system, BlinkMacSystemFont, sans-serif; }
            main { max-width: 760px; padding: 48px; border: 1px solid #ffffff33; border-radius: 32px; background: #ffffff12; box-shadow: 0 24px 90px #0008; }
            h1 { font-size: clamp(44px, 9vw, 92px); line-height: .9; margin: 0 0 16px; letter-spacing: -.07em; }
            p { color: #c9f7ff; font-weight: 700; font-size: 18px; }
          </style>
        </head>
        <body><main><h1>Robotics that ship.</h1><p>Autonomous launch page proof generated inside NovaForge.</p></main></body>
        </html>
        """
        try? runtime.workspace.write(artifact.path, contents: html)

        let greeting = ChatMessage(
            role: .assistant,
            content: "Hello! How can I help you with your iOS project or workspace today? Feel free to ask me to inspect files, edit code, build something new, or anything else you need.",
            conversation: conversation
        )
        let priorUser = ChatMessage(
            role: .user,
            content: "Yessir",
            conversation: conversation
        )
        let priorAssistant = ChatMessage(
            role: .assistant,
            content: "Let me check the current workspace state so I'm ready for your request. The workspace currently has a few Swift files, proof artifacts, and a recent verification run. This scrollback exists so completed-run controls can be tested while reading older chat context.",
            conversation: conversation
        )
        let user = ChatMessage(
            role: .user,
            content: "Build a landing page at cron-18-landing.html for a robotics startup.",
            conversation: conversation
        )
        let assistant = ChatMessage(
            role: .assistant,
            content: "Local web artifact ready. Open cron-18-landing.html from Run Control.",
            conversation: conversation
        )
        conversation.appendMessages([greeting, priorUser, priorAssistant, user, assistant])
        modelContext.insert(greeting)
        modelContext.insert(priorUser)
        modelContext.insert(priorAssistant)
        modelContext.insert(user)
        modelContext.insert(assistant)

        let arguments = [
            "path": artifact.path,
            "contents": html
        ]
        let argumentsJSON = (try? String(
            data: JSONSerialization.data(withJSONObject: arguments, options: [.sortedKeys]),
            encoding: .utf8
        )) ?? "{\"path\":\"cron-18-landing.html\"}"
        let run = ToolRun(
            name: "write_file",
            argumentsJSON: argumentsJSON,
            output: "Wrote \(artifact.path)",
            status: .completed,
            requiresApproval: false,
            isMutating: true,
            project: activeProject
        )
        run.completedAt = Date()
        modelContext.insert(run)
        conversation.project = conversation.project ?? activeProject
        ProjectEventRecorder.ensureArtifact(
            artifact,
            project: activeProject,
            sourceToolRunID: run.id,
            context: modelContext
        )
        runtime.debugInstallCompletedArtifact(artifact)
        conversation.refreshMessageMetadata(updateTimestamp: Date())
    }

    private func installCompletedSwiftGameArtifactFixture(in conversation: Conversation) {
        let artifact = WorkspaceArtifact(path: SwiftGameArtifactFactory.sampleManifestPath)
        let manifestJSON = SwiftGameArtifactFactory.sampleManifestJSON()
        try? runtime.workspace.write(SwiftGameArtifactFactory.sampleManifestPath, contents: manifestJSON)
        try? runtime.workspace.write(SwiftGameArtifactFactory.sampleSourcePath, contents: SwiftGameArtifactFactory.exportSource())
        try? runtime.workspace.write(SwiftGameArtifactFactory.sampleReadmePath, contents: SwiftGameArtifactFactory.readme())

        let user = ChatMessage(
            role: .user,
            content: "Create a native Swift game artifact demo.",
            conversation: conversation
        )
        let assistant = ChatMessage(
            role: .assistant,
            content: "Native Swift game artifact ready. Open StarfieldSprint.nf-game.json to play it.",
            conversation: conversation
        )
        conversation.appendMessages([user, assistant])
        modelContext.insert(user)
        modelContext.insert(assistant)

        let run = ToolRun(
            name: "write_file",
            argumentsJSON: jsonString(["path": artifact.path, "contents": manifestJSON]),
            output: "Wrote \(artifact.path)",
            status: .completed,
            requiresApproval: false,
            isMutating: true,
            project: activeProject
        )
        run.completedAt = Date()
        modelContext.insert(run)
        conversation.project = conversation.project ?? activeProject
        ProjectEventRecorder.ensureArtifact(
            artifact,
            project: activeProject,
            sourceToolRunID: run.id,
            context: modelContext
        )
        runtime.debugInstallCompletedArtifact(artifact)
        conversation.refreshMessageMetadata(updateTimestamp: Date())
    }

    private func installProjectRunningFixture(for project: Project, conversation: Conversation) {
        let now = Date()
        project.name = "Release Readiness"
        project.mission = "Keep ProjectOS focused on the release check while Chat remains available for a separate conversation."
        project.nextStep = "Finish the release check and capture proof before marking the project ready."
        project.status = .running
        project.blocker = ""
        conversation.project = project

        let summary = ProjectMissionSummarizer.summarize(project: project, context: modelContext)
        ProjectOSRunLedger.startRun(
            project: project,
            summary: summary,
            intent: .verifyWork,
            operatorNote: "Run the release verification gate and keep Chat separate.",
            sourceConversationID: conversation.id,
            origin: .fixture,
            context: modelContext,
            now: now.addingTimeInterval(-8)
        )
        ProjectEventRecorder.record(
            project: project,
            kind: .agentPlanCreated,
            title: "Agent plan prepared",
            detail: "Inspect project context, patch the release check surface, then run xcodebuild before proof capture.",
            severity: .running,
            sourceType: .conversation,
            sourceID: conversation.id,
            context: modelContext,
            now: now.addingTimeInterval(-7)
        )
        ProjectEventRecorder.recordFileChange(
            project: project,
            action: "Updated ProjectOS release surface",
            path: "AgentPad/Views/ProjectDashboardView.swift",
            context: modelContext,
            now: now.addingTimeInterval(-5)
        )

        let command = "xcodebuild -project AgentPad.xcodeproj -scheme AgentPad -sdk iphonesimulator test"
        let terminal = TerminalCommandRecord(
            project: project,
            command: command,
            output: "Testing AgentPad... ProjectOS release check is still running.",
            status: .completed,
            workspaceName: projectRuntime.workspace.workspaceName,
            startedAt: now.addingTimeInterval(-3),
            completedAt: now.addingTimeInterval(-1),
            durationMs: 2000
        )
        modelContext.insert(terminal)
        ProjectEventRecorder.record(
            project: project,
            kind: .terminalCommand,
            title: "Running release check",
            detail: command,
            severity: .running,
            sourceType: .terminalCommand,
            sourceID: terminal.id,
            metadata: [
                "command": command,
                "workspace": projectRuntime.workspace.workspaceName
            ],
            context: modelContext,
            now: now.addingTimeInterval(-1)
        )

        projectRuntime.debugSimulateActiveStatusStripRun(conversation: conversation)
        projectRuntime.activityTitle = "Running release check"
        projectRuntime.activityDetail = "ProjectOS is verifying the active project while Chat remains separate."
    }

    private func installProjectBlockedFixture(for project: Project, conversation: Conversation) {
        let now = Date()
        project.name = "Blocked Proof"
        project.mission = "Recover a ProjectOS proof receipt after validation catches missing durable metadata."
        project.nextStep = "Fix the proof receipt metadata and rerun validation."
        project.status = .blocked
        project.blocker = "project-os-proof.html is missing durable proof metadata."
        conversation.project = project

        let summary = ProjectMissionSummarizer.summarize(project: project, context: modelContext)
        ProjectOSRunLedger.startRun(
            project: project,
            summary: summary,
            intent: .fixBlocker,
            operatorNote: "Inspect the failed validation and make the smallest recovery edit.",
            sourceConversationID: conversation.id,
            origin: .fixture,
            context: modelContext,
            now: now.addingTimeInterval(-8)
        )
        let run = ToolRun(
            name: "validate_html_file",
            argumentsJSON: jsonString(["path": "project-os-proof.html"]),
            output: "Error: project-os-proof.html is missing durable proof metadata.",
            status: .failed,
            requiresApproval: false,
            isMutating: false,
            project: project
        )
        run.createdAt = now.addingTimeInterval(-5)
        run.completedAt = now.addingTimeInterval(-4)
        modelContext.insert(run)

        ProjectEventRecorder.record(
            project: project,
            kind: .agentPlanCreated,
            title: "Agent plan prepared",
            detail: "Inspect failed validation and retry with the smallest recovery step.",
            severity: .running,
            sourceType: .conversation,
            sourceID: conversation.id,
            context: modelContext,
            now: now.addingTimeInterval(-6)
        )

        let terminal = TerminalCommandRecord(
            project: project,
            command: "validate_html_file project-os-proof.html",
            output: run.output,
            status: .failed,
            workspaceName: projectRuntime.workspace.workspaceName,
            startedAt: run.createdAt,
            completedAt: run.completedAt ?? now,
            durationMs: 1000,
            sourceToolRunID: run.id
        )
        modelContext.insert(terminal)
        ProjectEventRecorder.record(
            project: project,
            kind: .terminalCommand,
            title: "Agent command failed",
            detail: terminal.command,
            severity: .failure,
            sourceType: .terminalCommand,
            sourceID: terminal.id,
            metadata: [
                "command": terminal.command,
                "workspace": projectRuntime.workspace.workspaceName,
                "toolRun": run.id.uuidString
            ],
            context: modelContext,
            now: now.addingTimeInterval(-3)
        )
        ProjectEventRecorder.record(
            project: project,
            kind: .runFailed,
            title: "Validation failed",
            detail: "project-os-proof.html needs a recovery pass before more autonomous work.",
            severity: .failure,
            sourceType: .toolRun,
            sourceID: run.id,
            context: modelContext,
            now: now.addingTimeInterval(-2)
        )
    }

    private func installProjectWaitingFixture(for project: Project, conversation: Conversation) {
        let now = Date()
        project.name = "Approval Gate"
        project.mission = "Prepare a ProjectOS proof receipt, then wait for approval before writing files."
        project.nextStep = "Approve the proof receipt write or adjust the path."
        project.status = .running
        project.blocker = ""
        conversation.project = project

        let summary = ProjectMissionSummarizer.summarize(project: project, context: modelContext)
        ProjectOSRunLedger.startRun(
            project: project,
            summary: summary,
            intent: .improveArtifact,
            operatorNote: "Wait for approval before writing the proof receipt.",
            sourceConversationID: conversation.id,
            origin: .fixture,
            context: modelContext,
            now: now.addingTimeInterval(-6)
        )
        ProjectEventRecorder.record(
            project: project,
            kind: .agentPlanCreated,
            title: "Agent plan prepared",
            detail: "Review the target proof file, request approval, then write only after confirmation.",
            severity: .running,
            sourceType: .conversation,
            sourceID: conversation.id,
            context: modelContext,
            now: now.addingTimeInterval(-5)
        )

        let approvalArguments = [
            "path": "project-os-proof.html",
            "contents": "<html><body><h1>ProjectOS proof receipt</h1></body></html>",
            "reason": "durable proof receipt"
        ]
        let run = ToolRun(
            name: "write_file",
            argumentsJSON: jsonString(approvalArguments),
            output: "",
            status: .pendingApproval,
            requiresApproval: true,
            isMutating: true,
            project: project
        )
        run.createdAt = now.addingTimeInterval(-3)
        modelContext.insert(run)
        ProjectEventRecorder.record(
            project: project,
            kind: .toolApprovalRequested,
            title: "Approval needed for write_file",
            detail: #"{"path":"project-os-proof.html","reason":"durable proof receipt"}"#,
            severity: .warning,
            sourceType: .toolRun,
            sourceID: run.id,
            metadata: [
                "tool": run.name,
                "path": "project-os-proof.html"
            ],
            context: modelContext,
            now: now.addingTimeInterval(-2)
        )

        let request = ToolRequest(id: "project-waiting-write", name: run.name, arguments: approvalArguments)
        projectRuntime.debugInstallPendingApproval(request: request, run: run)
        projectRuntime.activityTitle = "Waiting for approval"
        projectRuntime.activityDetail = "ProjectOS is paused before write_file can mutate project files."
    }

    private func installProjectResumeFixture(for project: Project, conversation: Conversation) {
        let now = Date()
        project.name = "Recovered Mission"
        project.mission = "Resume a ProjectOS run that was interrupted before proof was captured."
        project.nextStep = "Resume from the stopped verification step and capture proof."
        project.status = .needsReview
        project.blocker = "Previous ProjectOS run stopped during relaunch recovery."
        conversation.project = project

        let summary = ProjectMissionSummarizer.summarize(project: project, context: modelContext)
        ProjectOSRunLedger.startRun(
            project: project,
            summary: summary,
            intent: .verifyWork,
            operatorNote: "Recover the interrupted verification and capture proof.",
            sourceConversationID: conversation.id,
            origin: .fixture,
            context: modelContext,
            now: now.addingTimeInterval(-8)
        )
        ProjectEventRecorder.record(
            project: project,
            kind: .agentPlanCreated,
            title: "Agent plan recovered",
            detail: "Resume verification from the stopped ProjectOS run.",
            severity: .running,
            sourceType: .conversation,
            sourceID: conversation.id,
            context: modelContext,
            now: now.addingTimeInterval(-7)
        )
        ProjectEventRecorder.record(
            project: project,
            kind: .runPaused,
            title: "Stopped after relaunch",
            detail: "The app relaunched before verification finished. Resume the mission from ProjectOS when ready.",
            severity: .warning,
            sourceType: .system,
            context: modelContext,
            now: now.addingTimeInterval(-5)
        )

        projectRuntime.pendingTool = nil
        projectRuntime.isWorking = false
        projectRuntime.runState = .idle
        projectRuntime.wasInterrupted = true
        projectRuntime.activityTitle = "Stopped after relaunch"
        projectRuntime.activityDetail = project.nextStep
    }

    private func installAutoContinueCountdownFixture(
        for project: Project,
        conversation: Conversation,
        settings: AgentSettings
    ) {
        let now = Date()
        project.name = "Command Center Polish"
        project.mission = "Ship a release-grade Project command center with durable run proof and clear next action."
        project.nextStep = "Continue the UI polish pass and verify the auto-continue handoff remains project-owned."
        project.status = .active
        project.blocker = ""
        project.autoContinueEnabled = true
        project.autoContinuePaused = false
        project.autoContinueState = .idle
        project.autoContinueFailureStreak = 0
        project.autoContinueDecision = "Auto-continue will start after the safety pause."
        project.autoContinueUpdatedAt = now

        settings.provider = .local
        settings.modelID = AIProvider.local.defaultModel
        settings.updatedAt = now
        projectRuntime.localModels.select(LocalModelCatalog.defaultVariant)

        conversation.project = project
        selectedConversationID = conversation.id
        let user = ChatMessage(
            role: .user,
            content: "Use the completed proof pass to continue the command center polish.",
            conversation: conversation
        )
        let assistant = ChatMessage(
            role: .assistant,
            content: "Completed the proof pass. Next safe step is ready and auto-continue is counting down.",
            conversation: conversation
        )
        user.createdAt = now.addingTimeInterval(-11)
        assistant.createdAt = now.addingTimeInterval(-1)
        conversation.appendMessages([user, assistant], updateTimestamp: now)
        modelContext.insert(user)
        modelContext.insert(assistant)

        let run = ToolRun(
            name: "project_state_check",
            argumentsJSON: jsonString(["scope": "command-center-auto-continue"]),
            output: "Project state check passed; next UI polish step is safe to continue.",
            status: .completed,
            requiresApproval: false,
            isMutating: false,
            project: project
        )
        run.createdAt = now.addingTimeInterval(-9)
        run.completedAt = now.addingTimeInterval(-7)
        modelContext.insert(run)

        ProjectEventRecorder.record(
            project: project,
            kind: .agentPlanCreated,
            title: "Agent plan prepared",
            detail: "Continue the command-center polish pass after proof is reviewed.",
            severity: .running,
            sourceType: .message,
            sourceID: user.id,
            context: modelContext,
            now: now.addingTimeInterval(-10)
        )
        ProjectEventRecorder.record(
            project: project,
            kind: .runCompleted,
            title: "Run completed",
            detail: "Project state check passed; next step selected.",
            severity: .success,
            sourceType: .conversation,
            sourceID: conversation.id,
            metadata: ["toolRun": run.id.uuidString],
            context: modelContext,
            now: now.addingTimeInterval(-6)
        )
        projectRuntime.pendingTool = nil
        projectRuntime.isWorking = false
        projectRuntime.runState = .completed
        projectRuntime.lastError = nil
        projectRuntime.wasInterrupted = false
        projectRuntime.activityTitle = "Next step ready"
        projectRuntime.activityDetail = project.nextStep
        try? modelContext.save()

        let evaluation = autoContinueEvaluation(for: project, settings: settings)
        if evaluation.action == .schedule {
            scheduleAutoContinue(project: project, settings: settings, evaluation: evaluation)
        } else {
            project.autoContinueState = .blocked
            project.autoContinueDecision = evaluation.detail
            project.autoContinueUpdatedAt = now
            try? modelContext.save()
        }
    }

    private func installProjectProofFixture(for project: Project, conversation: Conversation) {
        let now = Date()
        let artifact = WorkspaceArtifact(path: "project-os-proof.html")
        project.name = "Proof Receipt"
        project.mission = "Capture a durable ProjectOS proof receipt and show the verified artifact as completion evidence."
        project.nextStep = "Review the proof receipt and decide whether to ship or continue."
        project.status = .needsReview
        project.blocker = ""
        conversation.project = conversation.project ?? project

        let summary = ProjectMissionSummarizer.summarize(project: project, context: modelContext)
        ProjectOSRunLedger.startRun(
            project: project,
            summary: summary,
            intent: .reviewEvidence,
            operatorNote: "Validate the proof receipt and surface the final evidence.",
            sourceConversationID: conversation.id,
            origin: .fixture,
            context: modelContext,
            now: now.addingTimeInterval(-9)
        )
        let html = """
        <!doctype html>
        <html lang="en">
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
          <title>Project OS Proof</title>
          <style>
            body { margin: 0; min-height: 100svh; display: grid; place-items: center; background: #08121f; color: #e9fbff; font-family: -apple-system, BlinkMacSystemFont, sans-serif; }
            main { width: min(86vw, 760px); border: 1px solid #75f6ff55; border-radius: 24px; padding: 28px; background: #ffffff12; }
            h1 { margin: 0 0 10px; font-size: clamp(36px, 9vw, 74px); line-height: .9; }
            p { margin: 0; color: #b8f8d8; font-weight: 800; }
          </style>
        </head>
        <body><main><h1>Project OS Proof</h1><p>Verified run receipt saved by NovaForge.</p></main></body>
        </html>
        """
        try? projectRuntime.workspace.write(artifact.path, contents: html)

        let run = ToolRun(
            name: "validate_html_file",
            argumentsJSON: jsonString(["path": artifact.path]),
            output: "HTML validation passed for \(artifact.path)",
            status: .completed,
            requiresApproval: false,
            isMutating: false,
            project: project
        )
        run.createdAt = now.addingTimeInterval(-7)
        run.completedAt = now.addingTimeInterval(-6)
        modelContext.insert(run)

        let user = ChatMessage(role: .user, content: "Verify the Project OS proof loop.", conversation: conversation)
        let assistant = ChatMessage(role: .assistant, content: "Agent Proof: checked \(artifact.path), captured durable proof, and found no active blocker.", conversation: conversation)
        user.createdAt = now.addingTimeInterval(-8)
        assistant.createdAt = now.addingTimeInterval(-1)
        conversation.appendMessages([user, assistant], updateTimestamp: now)
        modelContext.insert(user)
        modelContext.insert(assistant)

        ProjectEventRecorder.record(
            project: project,
            kind: .agentPlanCreated,
            title: "Agent plan prepared",
            detail: "Validate \(artifact.path) and save proof.",
            severity: .running,
            sourceType: .message,
            sourceID: user.id,
            context: modelContext,
            now: now.addingTimeInterval(-7.5)
        )

        let terminal = TerminalCommandRecord(
            project: project,
            command: "validate_html_file \(artifact.path)",
            output: run.output,
            status: .completed,
            workspaceName: projectRuntime.workspace.workspaceName,
            startedAt: run.createdAt,
            completedAt: run.completedAt ?? now,
            durationMs: 1000,
            sourceToolRunID: run.id
        )
        modelContext.insert(terminal)
        ProjectEventRecorder.record(
            project: project,
            kind: .terminalCommand,
            title: "Agent command completed",
            detail: terminal.command,
            severity: .success,
            sourceType: .terminalCommand,
            sourceID: terminal.id,
            metadata: [
                "command": terminal.command,
                "workspace": projectRuntime.workspace.workspaceName,
                "toolRun": run.id.uuidString
            ],
            context: modelContext,
            now: now.addingTimeInterval(-5)
        )
        ProjectEventRecorder.ensureArtifact(
            artifact,
            project: project,
            sourceToolRunID: run.id,
            context: modelContext,
            now: now.addingTimeInterval(-4)
        )
        ProjectEventRecorder.recordFileChange(
            project: project,
            action: "Saved proof",
            path: artifact.path,
            sourceToolRunID: run.id,
            sourceTerminalCommandID: terminal.id,
            context: modelContext,
            now: now.addingTimeInterval(-3)
        )
        ProjectEventRecorder.record(
            project: project,
            kind: .runCompleted,
            title: "Run completed",
            detail: "Validated \(artifact.path)",
            severity: .success,
            sourceType: .toolRun,
            sourceID: run.id,
            context: modelContext,
            now: now.addingTimeInterval(-2)
        )
        ProjectEventRecorder.record(
            project: project,
            kind: .agentProofCreated,
            title: "Agent proof captured",
            detail: "Validated \(artifact.path)",
            severity: .success,
            sourceType: .conversation,
            sourceID: conversation.id,
            context: modelContext,
            now: now.addingTimeInterval(-1)
        )
        ProjectEventRecorder.recordMissionCheckpoint(
            project: project,
            trigger: "project-proof-demo",
            sourceType: .conversation,
            sourceID: conversation.id,
            context: modelContext,
            now: now
        )
        projectRuntime.debugInstallCompletedArtifact(artifact)
        conversation.refreshMessageMetadata(updateTimestamp: now)
    }

    private func installProjectSpineE2EFixture(for project: Project, conversation: Conversation) {
        let now = Date()
        let artifact = WorkspaceArtifact(path: "workflow-spine-proof.html")
        project.name = "Alpha Product Spine"
        project.mission = "Build, inspect, iterate, recover, and prove a durable iPhone-native workbench artifact."
        project.nextStep = "Review the latest proof, then ask for the next artifact iteration if needed."
        project.status = .needsReview
        project.blocker = ""
        conversation.project = project

        let html = """
        <!doctype html>
        <html lang="en">
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
          <title>NovaForge Spine Proof</title>
          <style>
            :root { color-scheme: dark; font-family: -apple-system, BlinkMacSystemFont, sans-serif; }
            * { box-sizing: border-box; }
            body { margin: 0; min-height: 100svh; display: grid; place-items: center; padding: max(18px, env(safe-area-inset-top)) max(18px, env(safe-area-inset-right)) max(18px, env(safe-area-inset-bottom)) max(18px, env(safe-area-inset-left)); background: linear-gradient(135deg, #07111f, #11332e); color: #eefcff; }
            .proof-card { width: min(88vw, 720px); max-height: calc(100svh - 36px); overflow: auto; border: 1px solid #75f6ff66; border-radius: 24px; padding: clamp(20px, 4vw, 30px); background: #ffffff14; box-shadow: 0 24px 60px #0008; }
            h1 { margin: 0 0 12px; font-size: clamp(32px, 6vw, 56px); line-height: 1; text-wrap: balance; }
            p { margin: 8px 0 0; color: #b8f8d8; font-size: clamp(17px, 3.2vw, 24px); font-weight: 800; }
            ul { margin: 18px 0 0; padding-left: 20px; color: #d9f7ff; font-size: clamp(16px, 3vw, 22px); font-weight: 700; line-height: 1.45; }
            @media (orientation: landscape) {
              body { padding: max(16px, env(safe-area-inset-top)) max(22px, env(safe-area-inset-right)) max(16px, env(safe-area-inset-bottom)) max(22px, env(safe-area-inset-left)); }
              .proof-card { width: min(78vw, 780px); padding: 24px 30px; }
              h1 { font-size: clamp(34px, 5.4vw, 54px); }
              p { font-size: clamp(18px, 2.8vw, 24px); }
              ul { font-size: clamp(16px, 2.3vw, 21px); }
            }
          </style>
        </head>
        <body>
          <section class="proof-card">
            <h1>NovaForge Spine Proof</h1>
            <p>Iteration 2 recovered, validated, and ready for review.</p>
            <ul>
              <li>Project memory retained mission, artifact, runs, and proof.</li>
              <li>Files, Runs, ProjectOS, and Chat point at this same artifact.</li>
              <li>The failed validation remains visible while current proof is clean.</li>
            </ul>
          </section>
        </body>
        </html>
        """
        try? projectRuntime.workspace.write(artifact.path, contents: html)

        let summary = ProjectMissionSummarizer.summarize(project: project, context: modelContext)
        ProjectOSRunLedger.startRun(
            project: project,
            summary: summary,
            intent: .improveArtifact,
            operatorNote: "Build the proof artifact, inspect it, iterate once, recover from a failed validation, and save current proof.",
            sourceConversationID: conversation.id,
            origin: .fixture,
            context: modelContext,
            now: now.addingTimeInterval(-52)
        )

        let firstUser = ChatMessage(role: .user, content: "Build a concrete ProjectOS proof artifact for the alpha product spine.", conversation: conversation)
        let firstAssistant = ChatMessage(role: .assistant, content: "Agent Plan: create workflow-spine-proof.html, validate it, and save proof in ProjectOS.", conversation: conversation)
        let iterateUser = ChatMessage(role: .user, content: "Improve the artifact so it explains iteration and recovery, then prove it again.", conversation: conversation)
        let failedAssistant = ChatMessage(role: .assistant, content: "Validation failed on the iteration. I kept the failed run visible and prepared a recovery pass.", conversation: conversation)
        let proofAssistant = ChatMessage(role: .assistant, content: "Agent Proof: recovered workflow-spine-proof.html, validated the updated artifact, and refreshed the project proof ledger.", conversation: conversation)
        firstUser.createdAt = now.addingTimeInterval(-51)
        firstAssistant.createdAt = now.addingTimeInterval(-49)
        iterateUser.createdAt = now.addingTimeInterval(-34)
        failedAssistant.createdAt = now.addingTimeInterval(-25)
        proofAssistant.createdAt = now.addingTimeInterval(-8)
        conversation.appendMessages([firstUser, firstAssistant, iterateUser, failedAssistant, proofAssistant], updateTimestamp: now)
        modelContext.insert(firstUser)
        modelContext.insert(firstAssistant)
        modelContext.insert(iterateUser)
        modelContext.insert(failedAssistant)
        modelContext.insert(proofAssistant)

        let firstRun = ToolRun(
            name: "validate_html_file",
            argumentsJSON: jsonString(["path": artifact.path, "iteration": "1"]),
            output: "HTML validation passed for \(artifact.path)",
            status: .completed,
            requiresApproval: false,
            isMutating: false,
            project: project
        )
        firstRun.createdAt = now.addingTimeInterval(-47)
        firstRun.completedAt = now.addingTimeInterval(-45)
        modelContext.insert(firstRun)

        ProjectEventRecorder.record(
            project: project,
            kind: .agentPlanCreated,
            title: "Agent plan prepared",
            detail: "Create \(artifact.path), validate it, and capture proof.",
            severity: .running,
            sourceType: .message,
            sourceID: firstUser.id,
            context: modelContext,
            now: now.addingTimeInterval(-50)
        )
        ProjectEventRecorder.recordFileChange(
            project: project,
            action: "Wrote artifact",
            path: artifact.path,
            sourceToolRunID: firstRun.id,
            context: modelContext,
            now: now.addingTimeInterval(-46)
        )
        let firstTerminal = TerminalCommandRecord(
            project: project,
            command: "validate_html_file \(artifact.path)",
            output: firstRun.output,
            status: .completed,
            workspaceName: projectRuntime.workspace.workspaceName,
            startedAt: firstRun.createdAt,
            completedAt: firstRun.completedAt ?? now,
            durationMs: 2000,
            sourceToolRunID: firstRun.id
        )
        modelContext.insert(firstTerminal)
        ProjectEventRecorder.record(
            project: project,
            kind: .terminalCommand,
            title: "Agent command completed",
            detail: firstTerminal.command,
            severity: .success,
            sourceType: .terminalCommand,
            sourceID: firstTerminal.id,
            metadata: ["command": firstTerminal.command, "workspace": projectRuntime.workspace.workspaceName, "toolRun": firstRun.id.uuidString],
            context: modelContext,
            now: now.addingTimeInterval(-44)
        )
        ProjectEventRecorder.ensureArtifact(
            artifact,
            project: project,
            sourceToolRunID: firstRun.id,
            context: modelContext,
            now: now.addingTimeInterval(-43)
        )
        ProjectEventRecorder.record(
            project: project,
            kind: .runCompleted,
            title: "Run completed",
            detail: "Validated initial \(artifact.path)",
            severity: .success,
            sourceType: .toolRun,
            sourceID: firstRun.id,
            context: modelContext,
            now: now.addingTimeInterval(-42)
        )
        ProjectEventRecorder.record(
            project: project,
            kind: .agentProofCreated,
            title: "Agent proof captured",
            detail: "Validated initial \(artifact.path)",
            severity: .success,
            sourceType: .conversation,
            sourceID: conversation.id,
            context: modelContext,
            now: now.addingTimeInterval(-41)
        )

        let failedRun = ToolRun(
            name: "validate_html_file",
            argumentsJSON: jsonString(["path": artifact.path, "iteration": "2"]),
            output: "Error: missing closing main tag in \(artifact.path)",
            status: .failed,
            requiresApproval: false,
            isMutating: false,
            project: project
        )
        failedRun.createdAt = now.addingTimeInterval(-30)
        failedRun.completedAt = now.addingTimeInterval(-29)
        modelContext.insert(failedRun)
        ProjectEventRecorder.record(
            project: project,
            kind: .agentPlanCreated,
            title: "Agent plan prepared",
            detail: "Improve \(artifact.path), then validate and refresh proof.",
            severity: .running,
            sourceType: .message,
            sourceID: iterateUser.id,
            context: modelContext,
            now: now.addingTimeInterval(-33)
        )
        ProjectEventRecorder.recordFileChange(
            project: project,
            action: "Improved artifact draft",
            path: artifact.path,
            context: modelContext,
            now: now.addingTimeInterval(-31)
        )
        let failedTerminal = TerminalCommandRecord(
            project: project,
            command: "validate_html_file \(artifact.path)",
            output: failedRun.output,
            status: .failed,
            workspaceName: projectRuntime.workspace.workspaceName,
            startedAt: failedRun.createdAt,
            completedAt: failedRun.completedAt ?? now,
            durationMs: 1000,
            sourceToolRunID: failedRun.id
        )
        modelContext.insert(failedTerminal)
        ProjectEventRecorder.record(
            project: project,
            kind: .terminalCommand,
            title: "Agent command failed",
            detail: failedTerminal.command,
            severity: .failure,
            sourceType: .terminalCommand,
            sourceID: failedTerminal.id,
            metadata: ["command": failedTerminal.command, "workspace": projectRuntime.workspace.workspaceName, "toolRun": failedRun.id.uuidString],
            context: modelContext,
            now: now.addingTimeInterval(-28)
        )
        ProjectEventRecorder.record(
            project: project,
            kind: .runFailed,
            title: "Validation failed",
            detail: "\(artifact.path) needed a recovery edit before proof could be trusted.",
            severity: .failure,
            sourceType: .toolRun,
            sourceID: failedRun.id,
            context: modelContext,
            now: now.addingTimeInterval(-27)
        )

        let recoveryRun = ToolRun(
            name: "validate_html_file",
            argumentsJSON: jsonString(["path": artifact.path, "iteration": "2-recovery"]),
            output: "HTML validation passed for recovered \(artifact.path)",
            status: .completed,
            requiresApproval: false,
            isMutating: false,
            project: project
        )
        recoveryRun.createdAt = now.addingTimeInterval(-18)
        recoveryRun.completedAt = now.addingTimeInterval(-16)
        modelContext.insert(recoveryRun)
        ProjectEventRecorder.recordFileChange(
            project: project,
            action: "Recovered artifact",
            path: artifact.path,
            sourceToolRunID: recoveryRun.id,
            context: modelContext,
            now: now.addingTimeInterval(-17)
        )
        let recoveryTerminal = TerminalCommandRecord(
            project: project,
            command: "validate_html_file \(artifact.path)",
            output: recoveryRun.output,
            status: .completed,
            workspaceName: projectRuntime.workspace.workspaceName,
            startedAt: recoveryRun.createdAt,
            completedAt: recoveryRun.completedAt ?? now,
            durationMs: 2000,
            sourceToolRunID: recoveryRun.id
        )
        modelContext.insert(recoveryTerminal)
        ProjectEventRecorder.record(
            project: project,
            kind: .terminalCommand,
            title: "Agent command completed",
            detail: recoveryTerminal.command,
            severity: .success,
            sourceType: .terminalCommand,
            sourceID: recoveryTerminal.id,
            metadata: ["command": recoveryTerminal.command, "workspace": projectRuntime.workspace.workspaceName, "toolRun": recoveryRun.id.uuidString],
            context: modelContext,
            now: now.addingTimeInterval(-15)
        )
        ProjectEventRecorder.ensureArtifact(
            artifact,
            project: project,
            sourceToolRunID: recoveryRun.id,
            context: modelContext,
            now: now.addingTimeInterval(-14)
        )
        ProjectEventRecorder.record(
            project: project,
            kind: .runCompleted,
            title: "Run completed",
            detail: "Recovered and validated \(artifact.path)",
            severity: .success,
            sourceType: .toolRun,
            sourceID: recoveryRun.id,
            context: modelContext,
            now: now.addingTimeInterval(-13)
        )
        ProjectEventRecorder.record(
            project: project,
            kind: .agentProofCreated,
            title: "Agent proof captured",
            detail: "Recovered and validated \(artifact.path)",
            severity: .success,
            sourceType: .conversation,
            sourceID: conversation.id,
            context: modelContext,
            now: now.addingTimeInterval(-12)
        )
        ProjectEventRecorder.noteArtifactPreview(
            artifact,
            project: project,
            context: modelContext,
            now: now.addingTimeInterval(-10)
        )
        ProjectEventRecorder.recordMissionCheckpoint(
            project: project,
            trigger: "project-spine-e2e-demo",
            sourceType: .conversation,
            sourceID: conversation.id,
            context: modelContext,
            now: now.addingTimeInterval(-9)
        )

        project.status = .needsReview
        project.blocker = ""
        project.nextStep = "Review the recovered proof, then ask for the next artifact iteration if needed."
        projectRuntime.debugInstallCompletedArtifact(artifact)
        conversation.refreshMessageMetadata(updateTimestamp: now)
    }

    private func jsonString(_ values: [String: String]) -> String {
        (try? String(
            data: JSONSerialization.data(withJSONObject: values, options: [.sortedKeys]),
            encoding: .utf8
        )) ?? "{}"
    }

    private func seedStreamingStressConversation(_ conversation: Conversation) {
        let baseDate = Date().addingTimeInterval(-120)
        let messages: [ChatMessage] = [
            ChatMessage(
                role: .user,
                content: "Stress the live streaming transcript and keep it pinned while tools update.",
                conversation: conversation
            ),
            ChatMessage(
                role: .assistant,
                content: "I’ll keep a running response at the bottom, grow the tool trace, and leave older context above so intentional scrolling can be tested.",
                conversation: conversation
            ),
            ChatMessage(
                role: .assistant,
                content: "Previous context: planning notes, tool setup, workspace checks, and a few paragraphs of scrollback. This makes the live response test behave like a real long chat instead of an empty launch card.",
                conversation: conversation
            ),
            ChatMessage(
                role: .assistant,
                content: "Scrollback checkpoint: the user should be able to pull away from the newest response, read this older content, then tap Latest to return without the app fighting them.",
                conversation: conversation
            )
        ]
        for (index, message) in messages.enumerated() {
            message.createdAt = baseDate.addingTimeInterval(TimeInterval(index * 8))
        }
        conversation.appendMessages(messages, updateTimestamp: Date())
    }

    private func applyDebugLaunchTabArgument() {
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--open-forge") || arguments.contains("--open-project") || arguments.contains("--open-chat") {
            selectedTab = .forge
        } else if arguments.contains("--open-workspace") || arguments.contains("--open-files") || arguments.contains("--open-terminal") {
            selectedTab = .workspace
        } else if arguments.contains("--open-history") || arguments.contains("--open-runs") {
            selectedTab = .history
        } else if arguments.contains("--open-control") || arguments.contains("--open-settings") {
            selectedTab = .control
        }
        // Sheets that used to hang off the Project tab now live on the
        // mission dossier cover — mount it so their demo flags can fire.
        if !showingMissionDossier,
           arguments.contains("--project-intake-demo") ||
           arguments.contains("--project-delete-confirm-demo") ||
           arguments.contains("--open-mission-dossier-demo") {
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(900))
                showingMissionDossier = true
            }
        }
    }

    private static func initialDebugLaunchTab() -> AppTab {
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--open-workspace") || arguments.contains("--open-files") || arguments.contains("--open-terminal") {
            return .workspace
        }
        if arguments.contains("--open-history") || arguments.contains("--open-runs") {
            return .history
        }
        if arguments.contains("--open-control") || arguments.contains("--open-settings") {
            return .control
        }
        return .forge
    }
    #endif

    #if !DEBUG && !targetEnvironment(simulator)
    private static func initialDebugLaunchTab() -> AppTab {
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--open-workspace") || arguments.contains("--open-files") || arguments.contains("--open-terminal") {
            return .workspace
        }
        if arguments.contains("--open-history") || arguments.contains("--open-runs") {
            return .history
        }
        if arguments.contains("--open-control") || arguments.contains("--open-settings") {
            return .control
        }
        return .forge
    }
    #endif

    private func makeConversationTitle() -> String {
        "NovaForge \(Self.conversationTitleFormatter.string(from: Date()))"
    }

    private static let conversationTitleFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, h:mm a"
        return formatter
    }()
}

private struct AppTabsRenderKey: Equatable {
    /// Only populated while frame profiling is active (launch argument), where
    /// per-tab profiling visibility must react to tab switches. In normal use
    /// this stays nil, so switching tabs does NOT re-key the whole TabView —
    /// the active-tab-dependent backdrops react through the environment
    /// instead (see `TabActivatedBackground`).
    let profilingSelectedTab: AppTab?
    let projectID: UUID
    let projectName: String
    let workspaceName: String
    let projectUpdatedAt: Date
    let conversationID: UUID
    let conversationTitle: String
    let conversationUpdatedAt: Date
    let conversationMessageCount: Int
    let settingsID: UUID
    let settingsUpdatedAt: Date
    let providerRawValue: String
    let modelID: String
    let runtimeStatus: WorkspaceStatusSnapshot
    let projectResumeDraftRevision: Int
    let autoContinueState: ProjectAutoContinueViewState
    let themeRawValue: String
    let performanceModeEnabled: Bool

    init(
        project: Project,
        conversation: Conversation,
        settings: AgentSettings,
        runtimeStatus: WorkspaceStatusSnapshot,
        selectedTab: AppTab,
        projectResumeDraftRevision: Int,
        autoContinueState: ProjectAutoContinueViewState,
        themeRawValue: String,
        performanceModeEnabled: Bool
    ) {
        self.profilingSelectedTab = AgentPerformance.shouldProfileFrameRate ? selectedTab : nil
        self.projectID = project.id
        self.projectName = project.name
        self.workspaceName = project.workspaceName
        self.projectUpdatedAt = project.updatedAt
        self.conversationID = conversation.id
        self.conversationTitle = conversation.title
        self.conversationUpdatedAt = conversation.updatedAt
        self.conversationMessageCount = conversation.messageCount
        self.settingsID = settings.id
        self.settingsUpdatedAt = settings.updatedAt
        self.providerRawValue = settings.provider.id
        self.modelID = settings.modelID
        self.runtimeStatus = runtimeStatus
        self.projectResumeDraftRevision = projectResumeDraftRevision
        self.autoContinueState = autoContinueState
        self.themeRawValue = themeRawValue
        self.performanceModeEnabled = performanceModeEnabled
    }
}

private struct AutoContinueRuntimeSignature: Equatable {
    let projectID: UUID?
    let projectUpdatedAt: Date?
    let runState: AgentRunState
    let isWorking: Bool
    let pendingToolName: String?
    let lastRunDuration: TimeInterval?

    @MainActor
    init(project: Project?, runtime: AgentRuntime) {
        self.projectID = project?.id
        self.projectUpdatedAt = project?.updatedAt
        self.runState = runtime.runState
        self.isWorking = runtime.isWorking
        self.pendingToolName = runtime.pendingTool?.name
        self.lastRunDuration = runtime.lastRunDuration
    }
}

private struct ConversationListSignature: Equatable {
    let count: Int
    let totalMessageCount: Int
    let newestUpdatedAt: Date?
    let fingerprint: Int

    init(conversations: [Conversation], projectID: UUID? = nil, limit: Int = 80) {
        var hasher = Hasher()
        var counted = 0
        var totalMessageCount = 0
        var newestUpdatedAt: Date?

        for conversation in conversations where projectID == nil || conversation.project?.id == projectID {
            counted += 1
            totalMessageCount += conversation.messageCount
            newestUpdatedAt = max(newestUpdatedAt ?? conversation.updatedAt, conversation.updatedAt)
            guard counted <= limit else { continue }
            hasher.combine(conversation.id)
            hasher.combine(conversation.updatedAt)
            hasher.combine(conversation.messageCount)
        }

        self.count = counted
        self.totalMessageCount = totalMessageCount
        self.newestUpdatedAt = newestUpdatedAt
        self.fingerprint = hasher.finalize()
    }
}

private struct ChatTabKey: Equatable {
    let projectID: UUID
    let projectName: String
    let workspaceName: String
    let scopedProjectID: UUID?
    let conversationID: UUID
    let conversationTitle: String
    let conversationUpdatedAt: Date
    let conversationMessageCount: Int
    let conversationsSignature: ConversationListSignature
    let settingsID: UUID
    let settingsUpdatedAt: Date
    let providerRawValue: String
    let modelID: String
    let projectResumeDraftRevision: Int
    let missionStatus: WorkspaceStatusSnapshot
    let missionAutoContinue: ProjectAutoContinueViewState
    let isVisibleForFrameProfiling: Bool
    let themeRawValue: String
    let performanceModeEnabled: Bool

    init(
        project: Project,
        conversation: Conversation,
        conversations: [Conversation],
        settings: AgentSettings,
        projectResumeDraftRevision: Int,
        missionStatus: WorkspaceStatusSnapshot,
        missionAutoContinue: ProjectAutoContinueViewState,
        isVisibleForFrameProfiling: Bool,
        themeRawValue: String,
        performanceModeEnabled: Bool
    ) {
        self.projectID = project.id
        self.projectName = project.name
        self.workspaceName = project.workspaceName
        self.scopedProjectID = conversation.project?.id
        self.conversationID = conversation.id
        self.conversationTitle = conversation.title
        self.conversationUpdatedAt = conversation.updatedAt
        self.conversationMessageCount = conversation.messageCount
        self.conversationsSignature = ConversationListSignature(conversations: conversations)
        self.settingsID = settings.id
        self.settingsUpdatedAt = settings.updatedAt
        self.providerRawValue = settings.provider.id
        self.modelID = settings.modelID
        self.projectResumeDraftRevision = projectResumeDraftRevision
        self.missionStatus = missionStatus
        self.missionAutoContinue = missionAutoContinue
        self.isVisibleForFrameProfiling = isVisibleForFrameProfiling
        self.themeRawValue = themeRawValue
        self.performanceModeEnabled = performanceModeEnabled
    }
}

private struct FilesTabKey: Equatable {
    let projectID: UUID
    let workspaceName: String
    let isVisible: Bool
    let themeRawValue: String
    let performanceModeEnabled: Bool

    init(project: Project, isVisible: Bool, themeRawValue: String, performanceModeEnabled: Bool) {
        self.projectID = project.id
        self.workspaceName = project.workspaceName
        self.isVisible = isVisible
        self.themeRawValue = themeRawValue
        self.performanceModeEnabled = performanceModeEnabled
    }
}

private struct RunsTabKey: Equatable {
    let projectID: UUID
    let workspaceName: String
    let isVisible: Bool
    let themeRawValue: String
    let performanceModeEnabled: Bool

    init(project: Project, isVisible: Bool, themeRawValue: String, performanceModeEnabled: Bool) {
        self.projectID = project.id
        self.workspaceName = project.workspaceName
        self.isVisible = isVisible
        self.themeRawValue = themeRawValue
        self.performanceModeEnabled = performanceModeEnabled
    }
}

private struct SettingsTabKey: Equatable {
    let projectID: UUID
    let workspaceName: String
    let settingsID: UUID
    let settingsUpdatedAt: Date
    let providerRawValue: String
    let modelID: String
    let isVisible: Bool
    let themeRawValue: String
    let performanceModeEnabled: Bool

    init(project: Project, settings: AgentSettings, isVisible: Bool, themeRawValue: String, performanceModeEnabled: Bool) {
        self.projectID = project.id
        self.workspaceName = project.workspaceName
        self.settingsID = settings.id
        self.settingsUpdatedAt = settings.updatedAt
        self.providerRawValue = settings.provider.id
        self.modelID = settings.modelID
        self.isVisible = isVisible
        self.themeRawValue = themeRawValue
        self.performanceModeEnabled = performanceModeEnabled
    }
}

private struct StableTabSurface<Key: Equatable, Content: View>: View, Equatable {
    nonisolated(unsafe) let key: Key
    let content: () -> Content

    init(key: Key, @ViewBuilder content: @escaping () -> Content) {
        self.key = key
        self.content = content
    }

    nonisolated static func == (lhs: StableTabSurface<Key, Content>, rhs: StableTabSurface<Key, Content>) -> Bool {
        lhs.key == rhs.key
    }

    var body: some View {
        content()
    }
}

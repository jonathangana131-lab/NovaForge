import SwiftData
import SwiftUI

struct ProjectDashboardView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Query private var dashboardRuns: [ToolRun]
    @Query private var dashboardEvents: [ProjectEvent]
    @Query private var dashboardArtifacts: [ProjectArtifact]
    @Query private var dashboardTerminalCommands: [TerminalCommandRecord]
    @Query private var dashboardFileChanges: [ProjectFileChange]
    @Query private var dashboardProjectOSRuns: [ProjectOSRun]
    @State private var selectedProofItem: ProjectProofItem?
    @State private var highlightedProjectID: UUID?
    @State private var cachedSummary: ProjectMissionSummary
    @State private var cachedProjectConversations: [Conversation]
    @State private var selectedCommandIntent: ProjectCommandIntent = .continueMission
    @State private var selectedDetailScope: ProjectDetailScope = .review
    @State private var commandContext = ""
    @State private var selectedCommandProjectID: UUID?
    @State private var showsAllProjects = false
    @State private var showsProjectDetails = false
    @SceneStorage("ProjectDashboardView.selectedDetailScope") private var restoredDetailScopeRawValue = "review"
    @SceneStorage("ProjectDashboardView.showsProjectDetails") private var restoredShowsProjectDetails = false
    @State private var showsProjectSwitcherSheet = false
    @State private var showsProjectIntakeSheet = false
    @State private var showsProjectEditSheet = false
    @State private var confirmingProjectDelete = false
    @State private var runStartFeedback = false
    @State private var projectScrollStartedAt: Date?
    @State private var didRunAutoScrollProfile = false
    @State private var didPresentProjectIntakeDemo = false
    @Namespace private var projectSwitchGlassNamespace
    let project: Project
    let projects: [Project]
    let runtimeStatus: WorkspaceStatusSnapshot
    let autoContinueState: ProjectAutoContinueViewState
    let conversations: [Conversation]
    let openTab: (AppTab) -> Void
    let stopWorkspaceRun: () -> Void
    let approvePendingTool: () -> Void
    let rejectPendingTool: () -> Void
    let setAutoContinueEnabled: (Project, Bool) -> Void
    let pauseAutoContinue: (Project) -> Void
    let cancelAutoContinue: (Project) -> Void
    let createProject: (ProjectIntakeDraft) -> Void
    let selectProject: (Project) -> Void
    let updateProject: (Project, ProjectEditDraft) -> Void
    let deleteProject: (Project) -> Void
    let runProjectCommand: (Project, ProjectCommandIntent, String) -> Void
    let draftProjectCommand: (Project, ProjectCommandIntent, String) -> Void
    let openArtifactLandscapeFullScreen: (WorkspaceArtifact) -> Void
    let isVisibleForFrameProfiling: Bool
    private static let projectScrollTopID = "projectScrollTop"
    private static let projectScrollBottomID = "projectScrollBottom"

    private enum ProjectDetailScope: String, CaseIterable, Identifiable {
        case review
        case plan
        case evidence
        case timeline

        var id: String { rawValue }

        var title: String {
            switch self {
            case .review: "Overview"
            case .plan: "Plan"
            case .evidence: "Proof"
            case .timeline: "Activity"
            }
        }

        var symbol: String {
            switch self {
            case .review: "gauge.with.dots.needle.bottom.50percent"
            case .plan: "list.bullet.clipboard.fill"
            case .evidence: "checkmark.seal.fill"
            case .timeline: "timeline.selection"
            }
        }
    }

    private enum DashboardExecutionState: String, CaseIterable, Identifiable {
        case idle
        case planning
        case running
        case waiting
        case approvalRequired
        case blocked
        case failed
        case succeeded
        case resumed
        case proofReady

        var id: String { rawValue }

        var shortTitle: String {
            switch self {
            case .idle: "Idle"
            case .planning: "Planning"
            case .running: "Running"
            case .waiting: "Waiting"
            case .approvalRequired: "Approval"
            case .blocked: "Blocked"
            case .failed: "Failed"
            case .succeeded: "Succeeded"
            case .resumed: "Resume"
            case .proofReady: "Proof"
            }
        }

        var headline: String {
            switch self {
            case .idle: "Ready for the next project command"
            case .planning: "Planning the execution path"
            case .running: "Active work is in progress"
            case .waiting: "Waiting on the next safe gate"
            case .approvalRequired: "Approval required before continuing"
            case .blocked: "Blocked until recovery clears the issue"
            case .failed: "Failure captured with recovery available"
            case .succeeded: "Run succeeded and is ready for review"
            case .resumed: "Interrupted work can be resumed"
            case .proofReady: "Proof is ready to inspect"
            }
        }

        var symbolName: String {
            switch self {
            case .idle: "target"
            case .planning: "list.bullet.clipboard.fill"
            case .running: "waveform"
            case .waiting: "hourglass"
            case .approvalRequired: "checkmark.shield.fill"
            case .blocked: "hand.raised.fill"
            case .failed: "xmark.octagon.fill"
            case .succeeded: "checkmark.circle.fill"
            case .resumed: "pause.circle.fill"
            case .proofReady: "checkmark.seal.fill"
            }
        }

        var ladderIndex: Int {
            switch self {
            case .idle: 0
            case .planning: 1
            case .running: 2
            case .waiting: 3
            case .approvalRequired: 4
            case .blocked: 5
            case .failed: 6
            case .succeeded: 7
            case .resumed: 8
            case .proofReady: 9
            }
        }
    }

    init(
        project: Project,
        projects: [Project],
        runtimeStatus: WorkspaceStatusSnapshot,
        autoContinueState: ProjectAutoContinueViewState,
        conversations: [Conversation],
        openTab: @escaping (AppTab) -> Void,
        stopWorkspaceRun: @escaping () -> Void,
        approvePendingTool: @escaping () -> Void,
        rejectPendingTool: @escaping () -> Void,
        setAutoContinueEnabled: @escaping (Project, Bool) -> Void,
        pauseAutoContinue: @escaping (Project) -> Void,
        cancelAutoContinue: @escaping (Project) -> Void,
        createProject: @escaping (ProjectIntakeDraft) -> Void,
        selectProject: @escaping (Project) -> Void,
        updateProject: @escaping (Project, ProjectEditDraft) -> Void,
        deleteProject: @escaping (Project) -> Void,
        runProjectCommand: @escaping (Project, ProjectCommandIntent, String) -> Void,
        draftProjectCommand: @escaping (Project, ProjectCommandIntent, String) -> Void,
        openArtifactLandscapeFullScreen: @escaping (WorkspaceArtifact) -> Void,
        isVisibleForFrameProfiling: Bool = true
    ) {
        self.project = project
        self.projects = projects
        self.runtimeStatus = runtimeStatus
        self.autoContinueState = autoContinueState
        self.conversations = conversations
        self.openTab = openTab
        self.stopWorkspaceRun = stopWorkspaceRun
        self.approvePendingTool = approvePendingTool
        self.rejectPendingTool = rejectPendingTool
        self.setAutoContinueEnabled = setAutoContinueEnabled
        self.pauseAutoContinue = pauseAutoContinue
        self.cancelAutoContinue = cancelAutoContinue
        self.createProject = createProject
        self.selectProject = selectProject
        self.updateProject = updateProject
        self.deleteProject = deleteProject
        self.runProjectCommand = runProjectCommand
        self.draftProjectCommand = draftProjectCommand
        self.openArtifactLandscapeFullScreen = openArtifactLandscapeFullScreen
        self.isVisibleForFrameProfiling = isVisibleForFrameProfiling

        let projectID = project.id

        var runsDescriptor = FetchDescriptor<ToolRun>(
            predicate: #Predicate<ToolRun> { run in
                run.project?.id == projectID
            },
            sortBy: [SortDescriptor(\ToolRun.createdAt, order: .reverse)]
        )
        runsDescriptor.fetchLimit = 96
        _dashboardRuns = Query(runsDescriptor)

        var eventsDescriptor = FetchDescriptor<ProjectEvent>(
            predicate: #Predicate<ProjectEvent> { event in
                event.project?.id == projectID
            },
            sortBy: [SortDescriptor(\ProjectEvent.createdAt, order: .reverse)]
        )
        eventsDescriptor.fetchLimit = 120
        _dashboardEvents = Query(eventsDescriptor)

        var artifactsDescriptor = FetchDescriptor<ProjectArtifact>(
            predicate: #Predicate<ProjectArtifact> { artifact in
                artifact.project?.id == projectID
            },
            sortBy: [SortDescriptor(\ProjectArtifact.updatedAt, order: .reverse)]
        )
        artifactsDescriptor.fetchLimit = 32
        _dashboardArtifacts = Query(artifactsDescriptor)

        var terminalDescriptor = FetchDescriptor<TerminalCommandRecord>(
            predicate: #Predicate<TerminalCommandRecord> { command in
                command.project?.id == projectID
            },
            sortBy: [SortDescriptor(\TerminalCommandRecord.completedAt, order: .reverse)]
        )
        terminalDescriptor.fetchLimit = 72
        _dashboardTerminalCommands = Query(terminalDescriptor)

        var fileChangesDescriptor = FetchDescriptor<ProjectFileChange>(
            predicate: #Predicate<ProjectFileChange> { change in
                change.project?.id == projectID
            },
            sortBy: [SortDescriptor(\ProjectFileChange.createdAt, order: .reverse)]
        )
        fileChangesDescriptor.fetchLimit = 72
        _dashboardFileChanges = Query(fileChangesDescriptor)

        var projectOSRunsDescriptor = FetchDescriptor<ProjectOSRun>(
            predicate: #Predicate<ProjectOSRun> { run in
                run.project?.id == projectID
            },
            sortBy: [SortDescriptor(\ProjectOSRun.updatedAt, order: .reverse)]
        )
        projectOSRunsDescriptor.fetchLimit = 16
        _dashboardProjectOSRuns = Query(projectOSRunsDescriptor)

        let initialConversations = Self.sortedProjectConversations(
            conversations,
            projectConversations: project.conversations,
            projectID: project.id
        )
        _cachedProjectConversations = State(initialValue: initialConversations)
        _cachedSummary = State(
            initialValue: Self.makeSummary(
                project: project,
                conversations: initialConversations,
                toolRuns: project.toolRuns,
                terminalCommands: project.terminalCommands,
                artifacts: project.artifacts,
                fileChanges: project.fileChanges,
                events: project.events
            )
        )
    }

    private var projectEvents: [ProjectEvent] {
        dashboardEvents
    }

    private var projectConversations: [Conversation] {
        cachedProjectConversations
    }

    private var projectRuns: [ToolRun] {
        dashboardRuns
    }

    private var projectArtifacts: [ProjectArtifact] {
        dashboardArtifacts
    }

    private var projectFileChanges: [ProjectFileChange] {
        dashboardFileChanges
    }

    private var projectOSRuns: [ProjectOSRun] {
        dashboardProjectOSRuns
    }

    private var activeProjectOSRun: ProjectOSRun? {
        projectOSRuns.first { !$0.status.isTerminal } ?? projectOSRuns.first
    }

    private var projectOSDisplaySteps: [ProjectOSDisplayStep] {
        if let activeProjectOSRun {
            let steps = activeProjectOSRun.steps.sorted { lhs, rhs in
                if lhs.orderIndex != rhs.orderIndex { return lhs.orderIndex < rhs.orderIndex }
                return lhs.createdAt < rhs.createdAt
            }
            return steps.map { step in
                ProjectOSDisplayStep(
                    id: step.id.uuidString,
                    title: step.title,
                    detail: step.detail,
                    reason: step.reason,
                    status: step.status,
                    command: step.command,
                    proof: step.proof,
                    resultSummary: step.resultSummary,
                    createdAt: step.createdAt,
                    startedAt: step.startedAt,
                    completedAt: step.completedAt,
                    symbolName: projectOSStepSymbol(step.key)
                )
            }
        }

        return ProjectOSPlanBuilder.makeSteps(
            project: project,
            summary: summary,
            intent: recommendedCommandIntent,
            operatorNote: trimmedCommandContext
        ).map { planned in
            ProjectOSDisplayStep(
                id: planned.key,
                title: planned.title,
                detail: planned.detail,
                reason: planned.reason,
                status: .pending,
                command: "",
                proof: "",
                resultSummary: "",
                createdAt: nil,
                startedAt: nil,
                completedAt: nil,
                symbolName: planned.symbolName
            )
        }
    }

    private var projectOSCompletedStepCount: Int {
        projectOSDisplaySteps.filter { $0.status == .completed }.count
    }

    private var projectOSProgressFraction: Double {
        guard !projectOSDisplaySteps.isEmpty else { return 0 }
        return Double(projectOSCompletedStepCount) / Double(projectOSDisplaySteps.count)
    }

    private var projectOSCurrentStep: ProjectOSDisplayStep? {
        projectOSDisplaySteps.first { $0.status == .running || $0.status == .planning || $0.status == .waiting || $0.status == .blocked } ??
            projectOSDisplaySteps.first { !$0.status.isTerminal } ??
            projectOSDisplaySteps.last
    }

    private var projectOSNextStep: ProjectOSDisplayStep? {
        guard let current = projectOSCurrentStep,
              let index = projectOSDisplaySteps.firstIndex(where: { $0.id == current.id }) else {
            return projectOSDisplaySteps.first
        }
        return projectOSDisplaySteps.dropFirst(index + 1).first { !$0.status.isTerminal }
    }

    private struct ProjectOSDisplayStep: Identifiable, Equatable {
        let id: String
        let title: String
        let detail: String
        let reason: String
        let status: ProjectOSStepStatus
        let command: String
        let proof: String
        let resultSummary: String
        let createdAt: Date?
        let startedAt: Date?
        let completedAt: Date?
        let symbolName: String
    }

    private var adaptiveIntent: ProjectOSIntentSnapshot {
        if let activeProjectOSRun {
            return activeProjectOSRun.currentIntent
        }
        return ProjectOSIntentDeriver.makeIdleIntent(project: project)
    }

    private var adaptiveIntentHistory: [ProjectOSIntentSnapshot] {
        activeProjectOSRun.map { Array($0.intentHistory.reversed()) } ?? [adaptiveIntent]
    }

    private var adaptiveIntentSurface: ProjectOSAdaptiveSurface {
        activeProjectOSRun?.selectedAdaptiveSurface ?? adaptiveIntent.preferredSurface
    }

    private var summary: ProjectMissionSummary {
        cachedSummary
    }

    private var primarySurfaceKey: ProjectPrimarySurfaceKey {
        let latestArtifact = projectArtifacts.first
        return ProjectPrimarySurfaceKey(
            projectID: project.id,
            projectName: project.name,
            workspaceName: project.workspaceName,
            summary: summary,
            latestArtifactID: latestArtifact?.id,
            latestArtifactPath: latestArtifact?.path,
            latestArtifactTitle: latestArtifact?.title,
            latestArtifactKindRawValue: latestArtifact?.kindRawValue,
            latestArtifactUpdatedAt: latestArtifact?.updatedAt,
            recommendedCommandIntent: recommendedCommandIntent,
            commandContext: trimmedCommandContext,
            commandRunBlocked: commandRunBlocked,
            showsWorkspaceStatusStrip: runtimeStatus.isVisible,
            runtimeStatusTitle: runtimeStatus.title,
            runtimeStatusDetail: runtimeStatus.detail,
            runtimeStatusTone: runtimeStatus.tone,
            runtimeStatusChangedText: runtimeStatus.changedText,
            runtimeStatusIsWorking: runtimeStatus.isWorking,
            runtimeProgressSteps: runtimeStatus.progressSteps,
            autoContinueState: autoContinueState,
            projectOSRunID: activeProjectOSRun?.id,
            projectOSRunStatusRawValue: activeProjectOSRun?.statusRawValue,
            projectOSRunUpdatedAt: activeProjectOSRun?.updatedAt,
            projectOSRunStepCount: activeProjectOSRun?.steps.count ?? 0
        )
    }

    private var dashboardSnapshotID: String {
        let projectMessageCount = Self.totalMessageCount(in: project.conversations)
        let fetchedMessageCount = Self.totalMessageCount(in: conversations)
        var components: [String] = []
        components.reserveCapacity(11)
        components.append(project.id.uuidString)
        components.append(String(project.updatedAt.timeIntervalSince1970))
        components.append(String(project.conversations.count))
        components.append(String(conversations.count))
        components.append(String(projectMessageCount))
        components.append(String(fetchedMessageCount))
        components.append(String(dashboardRuns.count))
        components.append(String(dashboardEvents.count))
        components.append(String(dashboardArtifacts.count))
        components.append(String(dashboardTerminalCommands.count))
        components.append(String(dashboardFileChanges.count))
        components.append(String(dashboardProjectOSRuns.count))
        components.append(String(activeProjectOSRun?.updatedAt.timeIntervalSince1970 ?? 0))
        components.append(activeProjectOSRun?.statusRawValue ?? "none")
        return components.joined(separator: "-")
    }

    private var sortedProjects: [Project] {
        projects.sorted { lhs, rhs in
            if lhs.id == project.id { return true }
            if rhs.id == project.id { return false }
            if lhs.lastActivityAt != rhs.lastActivityAt { return lhs.lastActivityAt > rhs.lastActivityAt }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    private var visibleSwitcherProjects: [Project] {
        showsAllProjects ? sortedProjects : Array(sortedProjects.prefix(4))
    }

    private var hiddenSwitcherProjectCount: Int {
        max(sortedProjects.count - visibleSwitcherProjects.count, 0)
    }

    private static func mergedConversations(
        _ conversations: [Conversation],
        projectConversations: [Conversation],
        projectID: UUID
    ) -> [Conversation] {
        var seenIDs = Set<UUID>()
        return (conversations + projectConversations).filter { conversation in
            guard conversation.project?.id == projectID else { return false }
            return seenIDs.insert(conversation.id).inserted
        }
    }

    private static func sortedProjectConversations(
        _ conversations: [Conversation],
        projectConversations: [Conversation],
        projectID: UUID
    ) -> [Conversation] {
        mergedConversations(conversations, projectConversations: projectConversations, projectID: projectID)
            .sorted { lhs, rhs in
                if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
                return lhs.createdAt > rhs.createdAt
            }
    }

    private static func totalMessageCount(in conversations: [Conversation]) -> Int {
        conversations.reduce(into: 0) { total, conversation in
            total += conversation.messageCount
        }
    }

    private static func makeSummary(
        project: Project,
        conversations: [Conversation],
        toolRuns: [ToolRun],
        terminalCommands: [TerminalCommandRecord],
        artifacts: [ProjectArtifact],
        fileChanges: [ProjectFileChange],
        events: [ProjectEvent]
    ) -> ProjectMissionSummary {
        ProjectMissionSummarizer.summarize(
            project: project,
            conversations: conversations,
            toolRuns: toolRuns,
            terminalCommands: terminalCommands,
            artifacts: artifacts,
            fileChanges: fileChanges,
            events: events
        )
    }

    private func refreshDashboardSnapshot() {
        let signpostID = AgentPerformance.begin("Project Summary Build")
        let activeConversations = Self.sortedProjectConversations(
            conversations,
            projectConversations: project.conversations,
            projectID: project.id
        )
        cachedProjectConversations = activeConversations
        cachedSummary = Self.makeSummary(
            project: project,
            conversations: activeConversations,
            toolRuns: dashboardRuns,
            terminalCommands: dashboardTerminalCommands,
            artifacts: dashboardArtifacts,
            fileChanges: dashboardFileChanges,
            events: dashboardEvents
        )
        AgentPerformance.end("Project Summary Build", id: signpostID)
    }

    private func syncRecommendedCommand(force: Bool = false) {
        guard force || selectedCommandProjectID != project.id else { return }
        selectedCommandProjectID = project.id
        selectedCommandIntent = recommendedCommandIntent
        commandContext = ""
    }

    private func restoreSelectedAdaptiveSurface() {
        if let activeProjectOSRun {
            selectedDetailScope = detailScope(for: activeProjectOSRun.selectedAdaptiveSurface)
            return
        }
        if let restoredScope = ProjectDetailScope(rawValue: restoredDetailScopeRawValue) {
            selectedDetailScope = restoredScope
        }
    }

    private func persistSelectedAdaptiveSurface(for scope: ProjectDetailScope) {
        restoredDetailScopeRawValue = scope.rawValue
        guard let activeProjectOSRun else { return }
        let surface = adaptiveSurface(for: scope)
        guard activeProjectOSRun.selectedAdaptiveSurface != surface else { return }
        activeProjectOSRun.selectedAdaptiveSurface = surface
        try? modelContext.save()
    }

    private func adaptiveSurface(for scope: ProjectDetailScope) -> ProjectOSAdaptiveSurface {
        switch scope {
        case .review: return .now
        case .plan: return .plan
        case .evidence: return .proof
        case .timeline: return .history
        }
    }

    private func detailScope(for surface: ProjectOSAdaptiveSurface) -> ProjectDetailScope {
        switch surface {
        case .now, .work: return .review
        case .plan: return .plan
        case .proof: return .evidence
        case .history: return .timeline
        }
    }

    var body: some View {
        let _ = AgentPerformance.bodyEvaluation("Project Dashboard Body")
        ZStack(alignment: .top) {
            VStack(spacing: 0) {
                projectPinnedCommandCenter
                    .padding(.horizontal)
                    .padding(.top, 10)
                    .padding(.bottom, 8)
                    .zIndex(3)

                ScrollViewReader { scrollProxy in
                    ScrollView(showsIndicators: false) {
                        VStack(alignment: .leading, spacing: 14) {
                            Color.clear
                                .frame(height: 1)
                                .id(Self.projectScrollTopID)
                                .accessibilityHidden(true)

                            ProjectStableSurface(key: primarySurfaceKey) {
                                projectOSControlCenter
                                    .projectScrollResponse(enabled: !reduceMotion && AgentPerformance.allowsDecorativeMotion)
                            }
                            .equatable()

                            projectOSWorkspaceSection

                            Color.clear
                                .frame(height: 1)
                                .id(Self.projectScrollBottomID)
                                .accessibilityHidden(true)
                        }
                        .padding(.horizontal)
                        .padding(.top, 6)
                    }
                    .scrollContentBackground(.hidden)
                    .scrollDismissesKeyboard(.interactively)
                    .agentDockEdgeFade()
                    .safeAreaInset(edge: .bottom, spacing: 0) {
                        BottomDockContentShield(height: BottomDockMetrics.scrollClearance)
                    }
                    .simultaneousGesture(projectScrollInstrumentationGesture)
                    .task(id: project.id) {
                        await runProjectAutoScrollProfileIfNeeded(scrollProxy)
                    }
                }
            }

            projectFrameRateProbe
        }
        .accessibilityIdentifier("projectDashboard")
        .onAppear {
            AgentPerformance.event("Project Dashboard Appear")
            highlightedProjectID = project.id
            showsProjectDetails = restoredShowsProjectDetails
            syncRecommendedCommand(force: true)
            restoreSelectedAdaptiveSurface()
            presentProjectIntakeDemoIfNeeded()
        }
        .task(id: dashboardSnapshotID) {
            try? await Task.sleep(for: .milliseconds(90))
            guard !Task.isCancelled else { return }
            refreshDashboardSnapshot()
        }
        .onChange(of: project.id) { _, newValue in
            withAnimation((reduceMotion || !AgentPerformance.allowsDecorativeMotion) ? nil : .smooth(duration: 0.42)) {
                highlightedProjectID = newValue
            }
            syncRecommendedCommand(force: true)
            restoreSelectedAdaptiveSurface()
        }
        .onChange(of: selectedDetailScope) { _, newValue in
            persistSelectedAdaptiveSurface(for: newValue)
        }
        .onChange(of: showsProjectDetails) { _, newValue in
            restoredShowsProjectDetails = newValue
        }
        .onChange(of: activeProjectOSRun?.id) {
            restoreSelectedAdaptiveSurface()
        }
        .sheet(item: $selectedProofItem) { item in
            proofDetailSheet(item)
        }
        .sheet(isPresented: $showsProjectSwitcherSheet) {
            projectSwitcherSheet
        }
        .sheet(isPresented: $showsProjectIntakeSheet) {
            ProjectIntakeSheet { draft in
                createProject(draft)
                showsProjectIntakeSheet = false
                showsProjectSwitcherSheet = false
            }
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showsProjectEditSheet) {
            ProjectEditSheet(project: project) { draft in
                updateProject(project, draft)
                showsProjectEditSheet = false
            }
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        }
        .confirmationDialog(
            "Delete \(project.name)?",
            isPresented: $confirmingProjectDelete,
            titleVisibility: .visible
        ) {
            Button("Delete Project", role: .destructive) {
                deleteProject(project)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the project record and its project timeline. Related chats remain available as general history.")
        }
    }

    private var projectScrollInstrumentationGesture: some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { _ in
                guard projectScrollStartedAt == nil else { return }
                projectScrollStartedAt = Date()
                AgentPerformance.event("Project Scroll Started")
            }
            .onEnded { value in
                guard let startedAt = projectScrollStartedAt else { return }
                let durationMilliseconds = max(0, Date().timeIntervalSince(startedAt) * 1_000)
                AgentPerformance.value("Project Scroll Duration ms", durationMilliseconds)
                AgentPerformance.value("Project Scroll Distance", Double(abs(value.translation.height)))
                AgentPerformance.event("Project Scroll Completed")
                projectScrollStartedAt = nil
            }
    }

    private func presentProjectIntakeDemoIfNeeded() {
        guard ProcessInfo.processInfo.arguments.contains("--project-intake-demo"),
              !didPresentProjectIntakeDemo else {
            return
        }
        didPresentProjectIntakeDemo = true
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(350))
            showsProjectIntakeSheet = true
        }
    }

    private func runProjectAutoScrollProfileIfNeeded(_ proxy: ScrollViewProxy) async {
        guard !didRunAutoScrollProfile else { return }
        guard ProcessInfo.processInfo.arguments.contains("--auto-project-scroll") else { return }
        didRunAutoScrollProfile = true
        try? await Task.sleep(for: .milliseconds(1_800))
        guard !Task.isCancelled else { return }

        projectScrollStartedAt = Date()
        AgentPerformance.event("Project Scroll Started")
        withAnimation(projectAutoScrollAnimation(duration: 1.1)) {
            proxy.scrollTo(Self.projectScrollBottomID, anchor: .bottom)
        }
        try? await Task.sleep(for: .milliseconds(1_300))
        guard !Task.isCancelled else { return }

        withAnimation(projectAutoScrollAnimation(duration: 1.0)) {
            proxy.scrollTo(Self.projectScrollTopID, anchor: .top)
        }
        try? await Task.sleep(for: .milliseconds(1_150))
        guard !Task.isCancelled else { return }

        if let startedAt = projectScrollStartedAt {
            let durationMilliseconds = max(0, Date().timeIntervalSince(startedAt) * 1_000)
            AgentPerformance.value("Project Scroll Duration ms", durationMilliseconds)
        }
        AgentPerformance.event("Project Scroll Completed")
        projectScrollStartedAt = nil
    }

    private func projectAutoScrollAnimation(duration: TimeInterval) -> Animation? {
        guard !reduceMotion else { return nil }
        return .smooth(duration: duration)
    }

    @ViewBuilder
    private var projectFrameRateProbe: some View {
        if AgentPerformance.shouldProfileFrameRate {
            PerformanceFrameProbe(
                surface: projectScrollStartedAt == nil ? .projectIdle : .projectScroll,
                isActive: isVisibleForFrameProfiling
            )
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    private var projectOSControlCenter: some View {
        let tint = projectOSTint
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: projectOSStatusSymbol)
                    .font(.system(size: 16, weight: .black))
                    .foregroundStyle(tint)
                    .frame(width: 38, height: 38)
                    .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 7) {
                        Text("Command Center")
                            .font(.system(size: 9.5, weight: .black, design: AgentPalette.interfaceFontDesign))
                            .foregroundStyle(tint)
                            .textCase(.uppercase)
                            .kerning(1.1)
                        Text(adaptiveIntent.mode.displayName)
                            .font(.system(size: 8.5, weight: .black, design: AgentPalette.interfaceFontDesign))
                            .foregroundStyle(tint)
                            .padding(.horizontal, 7)
                            .frame(height: 19)
                            .background(tint.opacity(0.10), in: Capsule(style: .continuous))
                            .accessibilityIdentifier("projectOSIntentMode")
                    }

                    Text(project.name)
                        .font(.system(size: 12, weight: .bold, design: AgentPalette.interfaceFontDesign))
                        .foregroundStyle(AgentPalette.secondaryText)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .accessibilityIdentifier("projectOSActiveProject")

                    Text(projectOSMissionText)
                        .font(.system(size: 17.5, weight: .black, design: AgentPalette.interfaceFontDesign))
                        .foregroundStyle(AgentPalette.ink)
                        .lineLimit(2)
                        .minimumScaleFactor(0.82)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("projectOSMission")
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if projectOSProgressFraction > 0 || runtimeStatus.isWorking {
                    Text("\(projectOSCompletedStepCount)/\(max(projectOSDisplaySteps.count, 1))")
                        .font(.system(size: 12, weight: .black, design: AgentPalette.interfaceFontDesign))
                        .monospacedDigit()
                        .foregroundStyle(tint)
                        .padding(.horizontal, 8)
                        .frame(height: 26)
                        .background(tint.opacity(0.10), in: Capsule(style: .continuous))
                        .accessibilityIdentifier("projectOSProgressCount")
                }
            }

            if projectOSProgressFraction > 0 || runtimeStatus.isWorking {
                ProgressView(value: projectOSProgressFraction, total: 1)
                    .progressViewStyle(.linear)
                    .tint(tint)
                    .frame(height: 7)
                    .clipShape(Capsule(style: .continuous))
                    .accessibilityLabel("ProjectOS progress")
                    .accessibilityValue("\(Int((projectOSProgressFraction * 100).rounded())) percent")
            }

            projectOSExecutionStatePanel
        }
        .padding(14)
        .agentGlass(radius: 24, interactive: false, tint: tint.opacity(0.13))
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(tint.opacity(0.20), lineWidth: 0.7)
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("projectOSControlCenter")
    }

    private var projectOSExecutionStatePanel: some View {
        let state = dashboardExecutionState
        let tint = dashboardExecutionTint(state)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: state.symbolName)
                    .font(.system(size: 13, weight: .black))
                    .foregroundStyle(tint)
                    .frame(width: 32, height: 32)
                    .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 7) {
                        Text("Execution State")
                            .font(.system(size: 8.5, weight: .black, design: AgentPalette.interfaceFontDesign))
                            .foregroundStyle(AgentPalette.tertiaryText)
                            .textCase(.uppercase)
                        Text(state.shortTitle)
                            .font(.system(size: 8.5, weight: .black, design: AgentPalette.interfaceFontDesign))
                            .foregroundStyle(tint)
                            .padding(.horizontal, 7)
                            .frame(height: 19)
                            .background(tint.opacity(0.10), in: Capsule(style: .continuous))
                            .accessibilityIdentifier("projectOSExecutionStatePill")
                    }

                    Text(state.headline)
                        .font(.system(size: 14.5, weight: .black, design: AgentPalette.interfaceFontDesign))
                        .foregroundStyle(AgentPalette.ink)
                        .lineLimit(2)
                        .minimumScaleFactor(0.82)
                        .accessibilityIdentifier("projectOSExecutionStateHeadline")

                    Text(projectOSExecutionStateDetail)
                        .font(.system(size: 10.5, weight: .semibold, design: AgentPalette.interfaceFontDesign))
                        .foregroundStyle(AgentPalette.secondaryText)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("projectOSExecutionStateDetail")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            projectOSExecutionStateLadder
            projectOSExecutionActionRow

            HStack(spacing: 7) {
                projectOSExecutionMetric(title: "Evidence", value: projectOSEvidenceSummaryText, symbol: "checkmark.seal.fill", tint: AgentPalette.green)
                projectOSExecutionMetric(title: "Logs", value: projectOSLogSummaryText, symbol: "doc.text.magnifyingglass", tint: AgentPalette.cyan)
            }
        }
        .padding(11)
        .background(tint.opacity(0.075), in: RoundedRectangle(cornerRadius: 17, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 17, style: .continuous)
                .strokeBorder(tint.opacity(0.18), lineWidth: 0.55)
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("projectOSExecutionStatePanel")
    }

    private var projectOSExecutionStateLadder: some View {
        // The previous implementation rendered ALL ten execution states as a
        // permanent chip grid — a state machine dumped into the UI. This is a
        // live journey rail instead: three phases (Plan → Build → Prove), the
        // current one lit with the execution tint and shimmering while work
        // is actually happening. The state pill + headline above already name
        // the precise state.
        let state = dashboardExecutionState
        let phase: Int
        switch state {
        case .idle, .waiting, .planning:
            phase = 0
        case .running, .approvalRequired, .blocked, .failed, .resumed:
            phase = 1
        case .succeeded, .proofReady:
            phase = 2
        }
        let live: Bool
        switch state {
        case .planning, .running, .approvalRequired:
            live = true
        default:
            live = false
        }
        return NovaExecutionJourneyRail(
            activePhase: phase,
            isLive: live,
            isTrouble: state == .failed || state == .blocked,
            tint: dashboardExecutionTint(state)
        )
        .accessibilityIdentifier("projectOSExecutionStateLadder")
    }

    @ViewBuilder
    private var projectOSExecutionActionRow: some View {
        // Navigation-only by design: Run / Stop / Approve / Resume live in ONE
        // place — the pinned command center at the top of the screen. This row
        // only ever offers context jumps (plus Reject during approvals, whose
        // affirmative twin is the pinned button).
        switch dashboardExecutionState {
        case .approvalRequired:
            HStack(spacing: 8) {
                projectOSIntentSmallButton(title: "Reject", symbol: "xmark.shield.fill", tint: AgentPalette.rose) {
                    rejectPendingTool()
                }
                projectOSIntentSmallButton(title: "Runs", symbol: "waveform.path.ecg", tint: AgentPalette.lilac) {
                    openTab(.runs)
                }
            }
            .accessibilityIdentifier("projectOSApprovalActions")
        case .running, .planning:
            HStack(spacing: 8) {
                projectOSIntentSmallButton(title: "Runs", symbol: "waveform.path.ecg", tint: AgentPalette.lilac) {
                    openTab(.runs)
                }
                projectOSIntentSmallButton(title: "Timeline", symbol: "timeline.selection", tint: AgentPalette.cyan) {
                    selectedDetailScope = .timeline
                }
            }
        case .blocked, .failed, .resumed:
            HStack(spacing: 8) {
                projectOSIntentSmallButton(title: "Timeline", symbol: "timeline.selection", tint: AgentPalette.cyan) {
                    selectedDetailScope = .timeline
                }
                projectOSIntentSmallButton(title: "Runs", symbol: "waveform.path.ecg", tint: AgentPalette.lilac) {
                    openTab(.runs)
                }
            }
        case .proofReady, .succeeded:
            HStack(spacing: 8) {
                projectOSIntentSmallButton(title: "Proof", symbol: "checkmark.seal.fill", tint: AgentPalette.green) {
                    selectedDetailScope = .evidence
                }
                projectOSIntentSmallButton(title: "Runs", symbol: "waveform.path.ecg", tint: AgentPalette.lilac) {
                    openTab(.runs)
                }
            }
        case .idle, .waiting:
            HStack(spacing: 8) {
                projectOSIntentSmallButton(title: "Plan", symbol: "list.bullet.clipboard.fill", tint: AgentPalette.cyan) {
                    selectedDetailScope = .plan
                }
                projectOSIntentSmallButton(title: "Runs", symbol: "waveform.path.ecg", tint: AgentPalette.lilac) {
                    openTab(.runs)
                }
            }
        }
    }

    private func projectOSExecutionMetric(title: String, value: String, symbol: String, tint: Color) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: symbol)
                .font(.system(size: 8.5, weight: .black))
                .foregroundStyle(tint)
                .frame(width: 20, height: 20)
                .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 7.5, weight: .black, design: AgentPalette.interfaceFontDesign))
                    .foregroundStyle(AgentPalette.tertiaryText)
                    .textCase(.uppercase)
                    .lineLimit(1)
                Text(value)
                    .font(.system(size: 9.5, weight: .semibold, design: AgentPalette.interfaceFontDesign))
                    .foregroundStyle(AgentPalette.secondaryText)
                    .lineLimit(2)
                    .minimumScaleFactor(0.78)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, minHeight: 50, alignment: .topLeading)
        .background(AgentPalette.row.opacity(0.46), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title): \(value)")
    }

    private var projectOSNowPanel: some View {
        let tint = projectOSTint
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: runtimeStatus.isWorking ? "waveform" : "dot.radiowaves.left.and.right")
                    .font(.system(size: 12, weight: .black))
                    .foregroundStyle(tint)
                    .frame(width: 28, height: 28)
                    .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 9, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    Text("Now")
                        .font(.system(size: 8.5, weight: .black, design: AgentPalette.interfaceFontDesign))
                        .foregroundStyle(AgentPalette.tertiaryText)
                        .textCase(.uppercase)
                    Text(projectOSCurrentActionText)
                        .font(.system(size: 14, weight: .black, design: AgentPalette.interfaceFontDesign))
                        .foregroundStyle(AgentPalette.ink)
                        .lineLimit(2)
                        .minimumScaleFactor(0.82)
                        .accessibilityIdentifier("projectOSCurrentAction")
                    Text(projectOSCurrentReasonText)
                        .font(.system(size: 10.5, weight: .semibold, design: AgentPalette.interfaceFontDesign))
                        .foregroundStyle(AgentPalette.secondaryText)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("projectOSCurrentReason")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if !projectOSCurrentCommandText.isEmpty {
                HStack(spacing: 7) {
                    Image(systemName: "terminal.fill")
                        .font(.system(size: 9, weight: .black))
                        .foregroundStyle(AgentPalette.cyan)
                    Text(projectOSCurrentCommandText)
                        .font(.system(size: 10, weight: .black, design: AgentPalette.interfaceFontDesign))
                        .foregroundStyle(AgentPalette.secondaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .accessibilityIdentifier("projectOSCurrentCommand")
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 7)
                .background(AgentPalette.row.opacity(0.50), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
        .padding(11)
        .background(tint.opacity(0.075), in: RoundedRectangle(cornerRadius: 17, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 17, style: .continuous)
                .strokeBorder(tint.opacity(0.16), lineWidth: 0.55)
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("projectOSNowPanel")
    }

    private var projectOSAdaptiveIntentPanel: some View {
        let intent = adaptiveIntent
        let tint = projectOSIntentTint(intent.mode)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: projectOSIntentSymbol(intent.mode))
                    .font(.system(size: 13, weight: .black))
                    .foregroundStyle(tint)
                    .frame(width: 30, height: 30)
                    .background(tint.opacity(0.11), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text("Current Focus")
                            .font(.system(size: 8.5, weight: .black, design: AgentPalette.interfaceFontDesign))
                            .foregroundStyle(AgentPalette.tertiaryText)
                            .textCase(.uppercase)
                        Text(intent.source.displayName)
                            .font(.system(size: 8, weight: .black, design: AgentPalette.interfaceFontDesign))
                            .foregroundStyle(tint)
                            .padding(.horizontal, 6)
                            .frame(height: 18)
                            .background(tint.opacity(0.10), in: Capsule(style: .continuous))
                        Text(intent.confidence.displayName)
                            .font(.system(size: 8, weight: .black, design: AgentPalette.interfaceFontDesign))
                            .foregroundStyle(AgentPalette.tertiaryText)
                            .lineLimit(1)
                    }

                    Text(intent.summary.isEmpty ? projectOSCurrentActionText : intent.summary)
                        .font(.system(size: 14.5, weight: .black, design: AgentPalette.interfaceFontDesign))
                        .foregroundStyle(AgentPalette.ink)
                        .lineLimit(2)
                        .minimumScaleFactor(0.82)
                        .accessibilityIdentifier("projectOSIntentSummary")

                    Text(intent.reason.isEmpty ? projectOSCurrentReasonText : intent.reason)
                        .font(.system(size: 10.5, weight: .semibold, design: AgentPalette.interfaceFontDesign))
                        .foregroundStyle(AgentPalette.secondaryText)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("projectOSIntentReason")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            projectOSIntentObjectRow(intent)
            projectOSAdaptiveModeContent(intent)

            if !adaptiveIntentHistory.isEmpty {
                projectOSIntentHistoryStrip
            }
        }
        .padding(11)
        .background(tint.opacity(0.075), in: RoundedRectangle(cornerRadius: 17, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 17, style: .continuous)
                .strokeBorder(tint.opacity(0.18), lineWidth: 0.55)
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("projectOSAdaptiveSurface")
    }

    @ViewBuilder
    private func projectOSAdaptiveModeContent(_ intent: ProjectOSIntentSnapshot) -> some View {
        switch intent.mode {
        case .planning, .readingContext:
            projectOSIntentPlanningContent(intent)
        case .inspectingFiles, .editingCode:
            projectOSIntentFileContent(intent)
        case .runningTool, .runningCommand, .runningTests, .verifyingOutput, .capturingScreenshot:
            projectOSIntentCommandContent(intent)
        case .waitingApproval:
            projectOSIntentApprovalContent(intent)
        case .blocked, .stoppedResumable:
            projectOSIntentRecoveryContent(intent)
        case .producingProof, .summarizingCompletion, .completedProof:
            projectOSIntentProofContent(intent)
        case .idle:
            projectOSIntentIdleContent(intent)
        }
    }

    private func projectOSIntentPlanningContent(_ intent: ProjectOSIntentSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            projectOSIntentDatum(
                title: "Plan Focus",
                value: projectOSCurrentStep?.detail ?? projectOSMissionText,
                symbol: "list.bullet.clipboard.fill",
                tint: AgentPalette.lilac,
                identifier: "plan-focus"
            )
            projectOSIntentDatum(
                title: "Next",
                value: intent.recommendedAction.isEmpty ? projectOSNextStepText : intent.recommendedAction,
                symbol: "arrow.right.circle.fill",
                tint: AgentPalette.cyan,
                identifier: "plan-next"
            )
        }
    }

    private func projectOSIntentFileContent(_ intent: ProjectOSIntentSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            projectOSIntentDatum(
                title: intent.mode == .editingCode ? "Editing File" : "Inspecting",
                value: intent.filePath.isEmpty ? intent.objectDetail : intent.filePath,
                symbol: intent.mode == .editingCode ? "doc.badge.gearshape.fill" : "doc.text.magnifyingglass",
                tint: AgentPalette.cyan,
                identifier: "file-object"
            )
            HStack(spacing: 8) {
                projectOSIntentSmallButton(title: "Files", symbol: "folder.fill", tint: AgentPalette.cyan) {
                    openTab(.files)
                }
                projectOSIntentSmallButton(title: "Proof", symbol: "checkmark.seal.fill", tint: AgentPalette.green) {
                    selectedDetailScope = .evidence
                }
            }
        }
    }

    private func projectOSIntentCommandContent(_ intent: ProjectOSIntentSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            projectOSIntentDatum(
                title: intent.mode == .runningTests ? "Test / Build Gate" : intent.objectKind.displayName,
                value: intent.command.isEmpty ? intent.objectDetail : intent.command,
                symbol: intent.mode == .runningTests ? "checkmark.shield.fill" : "terminal.fill",
                tint: intent.mode == .runningTests ? AgentPalette.green : AgentPalette.cyan,
                identifier: "command-object"
            )
            HStack(spacing: 8) {
                if runtimeStatus.isWorking {
                    projectOSIntentSmallButton(title: "Stop", symbol: "stop.fill", tint: AgentPalette.rose) {
                        stopWorkspaceRun()
                    }
                }
                projectOSIntentSmallButton(title: "Runs", symbol: "waveform.path.ecg", tint: AgentPalette.lilac) {
                    openTab(.runs)
                }
            }
        }
    }

    private func projectOSIntentApprovalContent(_ intent: ProjectOSIntentSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            projectOSIntentDatum(
                title: "Approval Needed",
                value: intent.objectDetail.isEmpty ? projectOSBlockerText : intent.objectDetail,
                symbol: "checkmark.shield.fill",
                tint: AgentPalette.cyan,
                identifier: "approval-object"
            )
            HStack(spacing: 8) {
                if runtimeStatus.tone == .approval {
                    projectOSIntentSmallButton(title: "Approve", symbol: "checkmark", tint: AgentPalette.green) {
                        approvePendingTool()
                    }
                    projectOSIntentSmallButton(title: "Reject", symbol: "xmark", tint: AgentPalette.rose) {
                        rejectPendingTool()
                    }
                } else {
                    projectOSIntentSmallButton(title: "Review", symbol: "arrow.up.right", tint: AgentPalette.cyan) {
                        openTab(.runs)
                    }
                }
            }
        }
    }

    private func projectOSIntentRecoveryContent(_ intent: ProjectOSIntentSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            projectOSIntentDatum(
                title: intent.mode == .blocked ? "Blocker" : "Resume State",
                value: intent.blocker.isEmpty ? projectOSBlockerText : intent.blocker,
                symbol: intent.mode == .blocked ? "exclamationmark.triangle.fill" : "pause.circle.fill",
                tint: intent.mode == .blocked ? AgentPalette.rose : AgentPalette.lilac,
                identifier: "recovery-object"
            )
            HStack(spacing: 8) {
                projectOSIntentSmallButton(title: "Retry", symbol: "arrow.clockwise", tint: AgentPalette.lilac) {
                    runProjectCommand(project, recommendedCommandIntent, trimmedCommandContext)
                }
                projectOSIntentSmallButton(title: "History", symbol: "timeline.selection", tint: AgentPalette.cyan) {
                    selectedDetailScope = .timeline
                }
            }
        }
    }

    private func projectOSIntentProofContent(_ intent: ProjectOSIntentSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            projectOSIntentDatum(
                title: "Proof",
                value: intent.proof.isEmpty ? projectOSProofText : intent.proof,
                symbol: "checkmark.seal.fill",
                tint: AgentPalette.green,
                identifier: "proof-object"
            )
            HStack(spacing: 8) {
                projectOSIntentSmallButton(title: "Proof", symbol: "checkmark.seal.fill", tint: AgentPalette.green) {
                    selectedDetailScope = .evidence
                }
                projectOSIntentSmallButton(title: "Runs", symbol: "waveform.path.ecg", tint: AgentPalette.lilac) {
                    openTab(.runs)
                }
            }
        }
    }

    private func projectOSIntentIdleContent(_ intent: ProjectOSIntentSnapshot) -> some View {
        projectOSIntentDatum(
            title: "Recommended Next Action",
            value: intent.recommendedAction.isEmpty ? projectOSNextStepText : intent.recommendedAction,
            symbol: "arrow.right.circle.fill",
            tint: commandTint(for: recommendedCommandIntent),
            identifier: "idle-next"
        )
    }

    private func projectOSIntentObjectRow(_ intent: ProjectOSIntentSnapshot) -> some View {
        let value = projectOSIntentObjectValue(intent)
        return projectOSIntentDatum(
            title: intent.objectKind.displayName,
            value: value.isEmpty ? "No current object" : value,
            symbol: projectOSIntentObjectSymbol(intent.objectKind),
            tint: projectOSIntentTint(intent.mode),
            identifier: "current-object"
        )
        .accessibilityIdentifier("projectOSIntentObject")
    }

    private var projectOSIntentHistoryStrip: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
                Image(systemName: "timeline.selection")
                    .font(.system(size: 9, weight: .black))
                    .foregroundStyle(AgentPalette.lilac)
                Text("Recent Decisions")
                    .font(.system(size: 9, weight: .black, design: AgentPalette.interfaceFontDesign))
                    .foregroundStyle(AgentPalette.tertiaryText)
                    .textCase(.uppercase)
                Spacer(minLength: 0)
                Text("\(adaptiveIntentHistory.count)")
                    .font(.system(size: 8.5, weight: .black, design: AgentPalette.interfaceFontDesign))
                    .foregroundStyle(AgentPalette.lilac)
            }
            HStack(spacing: 6) {
                ForEach(Array(adaptiveIntentHistory.prefix(4))) { item in
                    Text(item.mode.displayName)
                        .font(.system(size: 8, weight: .black, design: AgentPalette.interfaceFontDesign))
                        .foregroundStyle(projectOSIntentTint(item.mode))
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                        .padding(.horizontal, 7)
                        .frame(height: 20)
                        .background(projectOSIntentTint(item.mode).opacity(0.09), in: Capsule(style: .continuous))
                }
                Spacer(minLength: 0)
            }
        }
        .padding(9)
        .background(AgentPalette.row.opacity(0.44), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("projectOSIntentHistory")
    }

    private var projectOSBriefColumns: [GridItem] {
        if dynamicTypeSize.isAccessibilitySize {
            return [GridItem(.flexible(), spacing: 8)]
        }
        return [
            GridItem(.flexible(), spacing: 8),
            GridItem(.flexible(), spacing: 8)
        ]
    }

    private func projectOSIntentDatum(
        title: String,
        value: String,
        symbol: String,
        tint: Color,
        identifier: String
    ) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 9.5, weight: .black))
                .foregroundStyle(tint)
                .frame(width: 22, height: 22)
                .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 8, weight: .black, design: AgentPalette.interfaceFontDesign))
                    .foregroundStyle(AgentPalette.tertiaryText)
                    .textCase(.uppercase)
                Text(value.isEmpty ? "None" : value)
                    .font(.system(size: 10.5, weight: .semibold, design: AgentPalette.interfaceFontDesign))
                    .foregroundStyle(AgentPalette.secondaryText)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(9)
        .background(AgentPalette.row.opacity(0.46), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title): \(value)")
        .accessibilityIdentifier("projectOSIntentDatum-\(identifier)")
    }

    private var projectOSCommandBriefPanel: some View {
        let tint = projectOSTint
        return VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: projectOSStatusSymbol)
                    .font(.system(size: 12, weight: .black))
                    .foregroundStyle(tint)
                    .frame(width: 28, height: 28)
                    .background(tint.opacity(0.11), in: RoundedRectangle(cornerRadius: 9, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    Text(projectOSStateHeadline)
                        .font(.system(size: 14, weight: .black, design: AgentPalette.interfaceFontDesign))
                        .foregroundStyle(AgentPalette.ink)
                        .lineLimit(2)
                        .minimumScaleFactor(0.82)
                        .accessibilityIdentifier("projectOSStateHeadline")

                    Text(projectOSStateDetail)
                        .font(.system(size: 10.5, weight: .semibold, design: AgentPalette.interfaceFontDesign))
                        .foregroundStyle(AgentPalette.secondaryText)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("projectOSStateDetail")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            LazyVGrid(columns: projectOSBriefColumns, spacing: 8) {
                projectOSBriefCell(
                    title: "Safe Next",
                    value: projectOSNextStepText,
                    symbol: "arrow.right.circle.fill",
                    tint: commandTint(for: recommendedCommandIntent),
                    identifier: "next"
                )
                projectOSBriefCell(
                    title: "Blocked / Waiting",
                    value: projectOSAttentionText,
                    symbol: projectOSAttentionSymbol,
                    tint: projectOSAttentionTint,
                    identifier: "attention"
                )
                projectOSBriefCell(
                    title: "Changed Output",
                    value: projectOSChangedText,
                    symbol: projectArtifacts.isEmpty ? "doc.badge.plus" : "shippingbox.fill",
                    tint: projectArtifacts.isEmpty ? AgentPalette.cyan : AgentPalette.green,
                    identifier: "changed"
                )
                projectOSBriefCell(
                    title: "Proof Exists",
                    value: projectOSProofText,
                    symbol: "checkmark.seal.fill",
                    tint: trustTint,
                    identifier: "proof"
                )
            }
        }
        .padding(11)
        .background(tint.opacity(0.075), in: RoundedRectangle(cornerRadius: 17, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 17, style: .continuous)
                .strokeBorder(tint.opacity(0.18), lineWidth: 0.55)
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("projectOSCommandBrief")
    }

    private func projectOSBriefCell(
        title: String,
        value: String,
        symbol: String,
        tint: Color,
        identifier: String
    ) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .black))
                .foregroundStyle(tint)
                .frame(width: 22, height: 22)
                .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 8, weight: .black, design: AgentPalette.interfaceFontDesign))
                    .foregroundStyle(AgentPalette.tertiaryText)
                    .textCase(.uppercase)
                Text(value.isEmpty ? "None" : value)
                    .font(.system(size: 10, weight: .semibold, design: AgentPalette.interfaceFontDesign))
                    .foregroundStyle(AgentPalette.secondaryText)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? 4 : 3)
                    .minimumScaleFactor(0.82)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .frame(minHeight: dynamicTypeSize.isAccessibilitySize ? 76 : 62, alignment: .topLeading)
        .background(AgentPalette.row.opacity(0.46), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title): \(value)")
        .accessibilityIdentifier("projectOSBrief-\(identifier)")
    }

    private func projectOSIntentSmallButton(
        title: String,
        symbol: String,
        tint: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            action()
        } label: {
            Label(title, systemImage: symbol)
                .font(.system(size: 10.5, weight: .black, design: AgentPalette.interfaceFontDesign))
                .frame(maxWidth: .infinity, minHeight: 34)
        }
        .buttonStyle(.plain)
        .foregroundStyle(AgentPalette.ink)
        .agentControlSurface(radius: 12, tint: tint.opacity(0.11), selected: false)
    }

    private var projectOSSnapshotGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
            projectOSSnapshotCell(
                title: "Current Step",
                value: projectOSCurrentStep?.title ?? "Ready",
                symbol: projectOSCurrentStep?.symbolName ?? "scope",
                tint: projectOSTint,
                identifier: "current-step"
            )
            projectOSSnapshotCell(
                title: "Next Step",
                value: projectOSNextStep?.title ?? projectOSNextStepText,
                symbol: "arrow.right.circle.fill",
                tint: AgentPalette.cyan,
                identifier: "next-step"
            )
            projectOSSnapshotCell(
                title: "Latest Event",
                value: activeProjectOSRun?.latestEventTitle ?? summary.lastEventTitle,
                symbol: "timeline.selection",
                tint: AgentPalette.lilac,
                identifier: "latest-event"
            )
            projectOSSnapshotCell(
                title: "Proof",
                value: projectOSProofText,
                symbol: "checkmark.seal.fill",
                tint: trustTint,
                identifier: "proof"
            )
        }
        .accessibilityIdentifier("projectOSSnapshotGrid")
    }

    private func projectOSSnapshotCell(
        title: String,
        value: String,
        symbol: String,
        tint: Color,
        identifier: String
    ) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .black))
                .foregroundStyle(tint)
                .frame(width: 22, height: 22)
                .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 8, weight: .black, design: AgentPalette.interfaceFontDesign))
                    .foregroundStyle(AgentPalette.tertiaryText)
                    .textCase(.uppercase)
                Text(value)
                    .font(.system(size: 10, weight: .semibold, design: AgentPalette.interfaceFontDesign))
                    .foregroundStyle(AgentPalette.secondaryText)
                    .lineLimit(2)
                    .minimumScaleFactor(0.82)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .frame(minHeight: 54, alignment: .topLeading)
        .background(AgentPalette.row.opacity(0.46), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title): \(value)")
        .accessibilityIdentifier("projectOSSnapshot-\(identifier)")
    }

    private var projectOSPlanPreviewPanel: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Label("Agent Plan", systemImage: "list.bullet.clipboard.fill")
                    .font(.system(size: 11, weight: .black, design: AgentPalette.interfaceFontDesign))
                    .foregroundStyle(AgentPalette.ink)
                Spacer(minLength: 0)
                Text(activeProjectOSRun == nil ? "Preview" : "Run \(projectOSStatusText)")
                    .font(.system(size: 9, weight: .black, design: AgentPalette.interfaceFontDesign))
                    .foregroundStyle(projectOSTint)
                    .lineLimit(1)
            }

            VStack(spacing: 0) {
                ForEach(Array(projectOSDisplaySteps.prefix(5).enumerated()), id: \.element.id) { index, step in
                    projectOSStepRow(step, isLast: index == min(projectOSDisplaySteps.count, 5) - 1)
                }
            }
            .background(AgentPalette.row.opacity(0.48), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .strokeBorder(projectOSTint.opacity(0.12), lineWidth: 0.55)
            )
        }
        .padding(11)
        .background(AgentPalette.surfaceAlt.opacity(0.30), in: RoundedRectangle(cornerRadius: 17, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("projectOSPlanPanel")
    }

    private func projectOSStepRow(_ step: ProjectOSDisplayStep, isLast: Bool) -> some View {
        let tint = projectOSStepTint(step.status)
        let timeText = projectOSStepTimeText(step)
        let resultText = projectOSStepResultText(step)
        return VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: step.symbolName)
                    .font(.system(size: 9.5, weight: .black))
                    .foregroundStyle(tint)
                    .frame(width: 24, height: 24)
                    .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(step.title)
                            .font(.system(size: 10.5, weight: .black, design: AgentPalette.interfaceFontDesign))
                            .foregroundStyle(AgentPalette.ink)
                            .lineLimit(1)
                            .minimumScaleFactor(0.82)
                        Text(step.status.displayName)
                            .font(.system(size: 7.5, weight: .black, design: AgentPalette.interfaceFontDesign))
                            .foregroundStyle(tint)
                            .lineLimit(1)
                        if !timeText.isEmpty {
                            Text(timeText)
                                .font(.system(size: 7.5, weight: .black, design: AgentPalette.interfaceFontDesign))
                                .foregroundStyle(AgentPalette.tertiaryText)
                                .lineLimit(1)
                                .minimumScaleFactor(0.75)
                        }
                    }
                    Text(step.detail)
                        .font(.system(size: 9.5, weight: .semibold, design: AgentPalette.interfaceFontDesign))
                        .foregroundStyle(AgentPalette.secondaryText)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    if !step.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text(step.command)
                            .font(.system(size: 8.5, weight: .black, design: AgentPalette.interfaceFontDesign))
                            .foregroundStyle(AgentPalette.cyan)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    if !resultText.isEmpty {
                        Text(resultText)
                            .font(.system(size: 9, weight: .bold, design: AgentPalette.interfaceFontDesign))
                            .foregroundStyle(tint)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(step.title). \(step.status.displayName). \(step.detail)")
            .accessibilityIdentifier("projectOSStep-\(step.id)")

            if !isLast {
                Divider()
                    .overlay(AgentPalette.border.opacity(0.30))
                    .padding(.leading, 43)
            }
        }
    }

    private func projectOSStepTimeText(_ step: ProjectOSDisplayStep) -> String {
        if let completedAt = step.completedAt {
            return "Done \(eventTimeText(completedAt))"
        }
        if let startedAt = step.startedAt {
            return "\(step.status == .waiting ? "Waiting" : "Started") \(eventTimeText(startedAt))"
        }
        if let createdAt = step.createdAt {
            return "Queued \(eventTimeText(createdAt))"
        }
        return ""
    }

    private func projectOSStepResultText(_ step: ProjectOSDisplayStep) -> String {
        let proof = step.proof.trimmingCharacters(in: .whitespacesAndNewlines)
        if !proof.isEmpty { return "Proof: \(proof)" }
        let result = step.resultSummary.trimmingCharacters(in: .whitespacesAndNewlines)
        if !result.isEmpty { return "Result: \(result)" }
        return ""
    }

    private var projectOSProofBlockerBand: some View {
        VStack(spacing: 8) {
            projectOSSignalRow(
                title: "Proof / Results",
                value: projectOSProofText,
                symbol: "checkmark.seal.fill",
                tint: trustTint,
                identifier: "proof-results"
            )
            projectOSSignalRow(
                title: projectOSBlockerTitle,
                value: projectOSBlockerText,
                symbol: projectOSBlockerSymbol,
                tint: projectOSBlockerTint,
                identifier: "blocker-waiting"
            )
            projectOSSignalRow(
                title: "Iteration",
                value: summary.workflowSpine.iterationPrompt,
                symbol: "arrow.triangle.2.circlepath",
                tint: AgentPalette.lilac,
                identifier: "iteration"
            )
        }
        .accessibilityIdentifier("projectOSProofBlockerBand")
    }

    private func projectOSSignalRow(
        title: String,
        value: String,
        symbol: String,
        tint: Color,
        identifier: String
    ) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .black))
                .foregroundStyle(tint)
                .frame(width: 24, height: 24)
                .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 8.5, weight: .black, design: AgentPalette.interfaceFontDesign))
                    .foregroundStyle(AgentPalette.tertiaryText)
                    .textCase(.uppercase)
                Text(value)
                    .font(.system(size: 10.5, weight: .semibold, design: AgentPalette.interfaceFontDesign))
                    .foregroundStyle(AgentPalette.secondaryText)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(10)
        .background(tint.opacity(0.065), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title): \(value)")
        .accessibilityIdentifier("projectOSSignal-\(identifier)")
    }

    private var projectOSWorkspaceSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            projectDetailScopePicker
            projectOSWorkspaceScopeContent
        }
        .padding(12)
        .agentGlass(radius: 22, interactive: false, tint: AgentPalette.cyan.opacity(0.07))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("projectOSWorkspaceSections")
    }

    @ViewBuilder
    private var projectOSWorkspaceScopeContent: some View {
        switch selectedDetailScope {
        case .review:
            projectOSOverviewDetail
        case .plan:
            projectOSPlanDetail
        case .evidence:
            projectOSProofDetail
        case .timeline:
            projectOSActivityDetail
        }
    }

    private var projectOSOverviewDetail: some View {
        VStack(alignment: .leading, spacing: 10) {
            projectOSMissionCard
            projectReviewDashboard
            if runtimeStatus.isVisible {
                projectRunStatusPanel
            }
        }
        .accessibilityIdentifier("projectOSOverviewSurface")
    }

    private var projectOSPlanDetail: some View {
        VStack(alignment: .leading, spacing: 10) {
            projectOSPlanPreviewPanel
            missionOSPanel
            missionOSGateSection
            projectCommandCenter
        }
        .accessibilityIdentifier("projectOSPlanSurface")
    }

    private var projectOSProofDetail: some View {
        VStack(alignment: .leading, spacing: 10) {
            latestEvidenceSection
            proofLedgerSection
            artifactsSection
            fileChangesSection
        }
        .accessibilityIdentifier("projectOSProofSurface")
    }

    private var projectOSActivityDetail: some View {
        VStack(alignment: .leading, spacing: 10) {
            projectOSExecutionTimelinePanel
            projectOSRunHistoryPanel
            projectSignals
            timelineSection
        }
        .accessibilityIdentifier("projectOSActivitySurface")
    }

    private var projectOSExecutionTimelinePanel: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Label("Execution Timeline", systemImage: "timeline.selection")
                    .font(.system(size: 11, weight: .black, design: AgentPalette.interfaceFontDesign))
                    .foregroundStyle(AgentPalette.ink)
                Spacer(minLength: 0)
                Text(projectOSExecutionTimelineSubtitle)
                    .font(.system(size: 9, weight: .black, design: AgentPalette.interfaceFontDesign))
                    .foregroundStyle(projectOSTint)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }

            VStack(spacing: 0) {
                ForEach(Array(projectOSDisplaySteps.enumerated()), id: \.element.id) { index, step in
                    projectOSStepRow(step, isLast: index == projectOSDisplaySteps.count - 1)
                }
            }
            .background(AgentPalette.row.opacity(0.52), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .strokeBorder(projectOSTint.opacity(0.14), lineWidth: 0.55)
            )
        }
        .padding(11)
        .background(AgentPalette.surfaceAlt.opacity(0.30), in: RoundedRectangle(cornerRadius: 17, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("projectOSExecutionTimeline")
    }

    private var projectOSExecutionTimelineSubtitle: String {
        if let run = activeProjectOSRun {
            let elapsed = projectOSRunElapsedText(run)
            return "\(run.status.displayName) · \(elapsed)"
        }
        return "Preview plan"
    }

    private var projectOSMissionCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Mission", systemImage: "scope")
                .font(.system(size: 11, weight: .black, design: AgentPalette.interfaceFontDesign))
                .foregroundStyle(AgentPalette.ink)
            Text(projectOSMissionText)
                .font(.system(size: 11.5, weight: .semibold, design: AgentPalette.interfaceFontDesign))
                .foregroundStyle(AgentPalette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            projectOSSignalRow(
                title: "Next Recommended Action",
                value: projectOSNextStepText,
                symbol: "arrow.right.circle.fill",
                tint: commandTint(for: recommendedCommandIntent),
                identifier: "next-action"
            )
        }
        .padding(11)
        .background(AgentPalette.row.opacity(0.52), in: RoundedRectangle(cornerRadius: 17, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("projectOSMissionPanel")
    }

    private var projectOSRunHistoryPanel: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Label("Run History", systemImage: "clock.arrow.circlepath")
                    .font(.system(size: 11, weight: .black, design: AgentPalette.interfaceFontDesign))
                    .foregroundStyle(AgentPalette.ink)
                Spacer(minLength: 0)
                Text("\(projectOSRuns.count)")
                    .font(.system(size: 9, weight: .black, design: AgentPalette.interfaceFontDesign))
                    .foregroundStyle(AgentPalette.cyan)
                    .padding(.horizontal, 7)
                    .frame(height: 20)
                    .background(AgentPalette.cyan.opacity(0.10), in: Capsule(style: .continuous))
            }

            if projectOSRuns.isEmpty {
                emptyState(title: "No ProjectOS runs yet", detail: "Start a mission to create a durable run with plan, steps, proof, and history.", symbol: "target", tint: AgentPalette.cyan)
            } else {
                VStack(spacing: 6) {
                    ForEach(projectOSRuns.prefix(5), id: \.id) { run in
                        projectOSRunHistoryRow(run)
                    }
                }
            }
        }
        .padding(11)
        .background(AgentPalette.row.opacity(0.52), in: RoundedRectangle(cornerRadius: 17, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("projectOSRunHistory")
    }

    private func projectOSRunHistoryRow(_ run: ProjectOSRun) -> some View {
        let tint = projectOSTint(for: run.status)
        return HStack(alignment: .top, spacing: 9) {
            Image(systemName: projectOSStatusSymbol(for: run.status))
                .font(.system(size: 10, weight: .black))
                .foregroundStyle(tint)
                .frame(width: 24, height: 24)
                .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(run.status.displayName)
                        .font(.system(size: 10, weight: .black, design: AgentPalette.interfaceFontDesign))
                        .foregroundStyle(AgentPalette.ink)
                    Text(eventTimeText(run.updatedAt))
                        .font(.system(size: 8.5, weight: .black, design: AgentPalette.interfaceFontDesign))
                        .foregroundStyle(AgentPalette.tertiaryText)
                    Text(projectOSRunElapsedText(run))
                        .font(.system(size: 8.5, weight: .black, design: AgentPalette.interfaceFontDesign))
                        .foregroundStyle(tint)
                        .lineLimit(1)
                }
                Text(run.currentAction.isEmpty ? run.latestEventTitle : run.currentAction)
                    .font(.system(size: 9.5, weight: .semibold, design: AgentPalette.interfaceFontDesign))
                    .foregroundStyle(AgentPalette.secondaryText)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 8)
        .background(tint.opacity(0.055), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(run.status.displayName). \(run.currentAction)")
    }

    private func projectOSRunElapsedText(_ run: ProjectOSRun) -> String {
        let startedAt = run.startedAt ?? run.createdAt
        let end = run.completedAt ?? run.updatedAt
        let seconds = max(0, end.timeIntervalSince(startedAt))
        if seconds < 60 {
            return "\(Int(seconds.rounded()))s"
        }
        let minutes = Int(seconds / 60)
        let remainder = Int(seconds) % 60
        return remainder == 0 ? "\(minutes)m" : "\(minutes)m \(remainder)s"
    }

    private var projectOSStatus: ProjectOSRunStatus {
        if let activeProjectOSRun {
            return activeProjectOSRun.status
        }
        if runStartFeedback { return .planning }
        if runtimeStatus.tone == .working { return .running }
        if runtimeStatus.tone == .approval { return .waiting }
        if runtimeStatus.tone == .error { return .failed }
        if runtimeStatus.tone == .paused { return .stopped }
        if summary.statusKind == .blocked { return .blocked }
        if summary.statusKind == .waiting { return .waiting }
        if summary.statusKind == .done { return .completed }
        return .idle
    }

    private var dashboardExecutionState: DashboardExecutionState {
        if runStartFeedback { return .planning }

        let status = projectOSStatus
        let projectIsBlocked = project.status == .blocked ||
            summary.statusKind == .blocked ||
            !summary.blocker.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if autoContinueState.state == .blocked { return .blocked }
        if autoContinueState.isCountingDown { return .waiting }

        switch status {
        case .blocked:
            return .blocked
        case .failed:
            return projectIsBlocked ? .blocked : .failed
        case .completed:
            return hasProjectOSProofEvidence ? .proofReady : .succeeded
        case .stopped:
            return .resumed
        case .waiting where summary.pendingApprovalCount > 0 || runtimeStatus.tone == .approval:
            return .approvalRequired
        default:
            break
        }

        switch runtimeStatus.tone {
        case .approval:
            return .approvalRequired
        case .error:
            return .failed
        case .paused:
            return .resumed
        case .working:
            return .running
        case .changed, .ready:
            break
        }

        switch status {
        case .idle:
            return .idle
        case .planning:
            return .planning
        case .running:
            return .running
        case .waiting:
            return summary.pendingApprovalCount > 0 ? .approvalRequired : .waiting
        case .blocked:
            return .blocked
        case .failed:
            return .failed
        case .completed:
            return hasProjectOSProofEvidence ? .proofReady : .succeeded
        case .stopped:
            return .resumed
        }
    }

    private var hasProjectOSProofEvidence: Bool {
        if !summary.proofItems.isEmpty || !projectArtifacts.isEmpty { return true }
        if let proof = activeProjectOSRun?.proofSummary.trimmingCharacters(in: .whitespacesAndNewlines),
           !proof.isEmpty {
            return true
        }
        if let artifacts = activeProjectOSRun?.artifactsSummary.trimmingCharacters(in: .whitespacesAndNewlines),
           !artifacts.isEmpty {
            return true
        }
        return false
    }

    private var projectOSStatusText: String {
        projectOSStatus.displayName
    }

    private var projectOSTint: Color {
        projectOSTint(for: projectOSStatus)
    }

    private var projectOSStatusSymbol: String {
        projectOSStatusSymbol(for: projectOSStatus)
    }

    private var projectOSStateHeadline: String {
        if runStartFeedback { return "Starting the next ProjectOS run" }

        switch projectOSStatus {
        case .idle:
            return "Ready for the next project step"
        case .planning:
            return "Planning the next move"
        case .running:
            return runtimeStatus.title == "Workspace ready" ? "Project run in progress" : runtimeStatus.title
        case .waiting:
            return runtimeStatus.tone == .approval ? "Approval needed before files change" : "Waiting on a project gate"
        case .blocked:
            return "Blocked until recovery runs"
        case .failed:
            return "Recovery available after failure"
        case .completed:
            return "Proof captured and ready to review"
        case .stopped:
            return "Paused with a resumable next step"
        }
    }

    private var projectOSStateDetail: String {
        if runStartFeedback { return "NovaForge has accepted the command and is opening the run lane." }
        if runtimeStatus.isVisible { return runtimeStatus.detail }

        switch projectOSStatus {
        case .idle:
            return summary.workflowSpine.currentDetail
        case .planning, .running:
            return projectOSCurrentReasonText
        case .waiting:
            return projectOSBlockerText
        case .blocked, .failed:
            return projectOSBlockerText
        case .completed:
            return projectOSProofText
        case .stopped:
            return projectOSBlockerText
        }
    }

    private var projectOSExecutionStateDetail: String {
        switch dashboardExecutionState {
        case .idle:
            return projectOSNextStepText
        case .planning:
            return projectOSCurrentReasonText
        case .running:
            return runtimeStatus.isVisible ? runtimeStatus.detail : projectOSCurrentReasonText
        case .waiting:
            if autoContinueState.isCountingDown {
                return "Auto-continue starts in \(autoContinueState.remainingSeconds)s. Pause or cancel before the countdown finishes."
            }
            return projectOSBlockerText
        case .approvalRequired:
            return runtimeStatus.tone == .approval ? runtimeStatus.detail : "A saved tool request needs an approve or reject decision before execution continues."
        case .blocked:
            return projectOSBlockerText
        case .failed:
            return projectOSBlockerText
        case .succeeded:
            return projectOSProofText
        case .resumed:
            return projectOSBlockerText
        case .proofReady:
            return projectOSProofText
        }
    }

    private var projectOSEvidenceSummaryText: String {
        var parts: [String] = []
        if !summary.proofItems.isEmpty {
            parts.append("\(summary.proofItems.count) proof\(summary.proofItems.count == 1 ? "" : "s")")
        }
        if !projectArtifacts.isEmpty {
            parts.append("\(projectArtifacts.count) artifact\(projectArtifacts.count == 1 ? "" : "s")")
        }
        if !projectFileChanges.isEmpty {
            parts.append("\(projectFileChanges.count) file\(projectFileChanges.count == 1 ? "" : "s")")
        }
        if parts.isEmpty { return "No proof yet" }
        return parts.joined(separator: " · ")
    }

    private var projectOSLogSummaryText: String {
        let runText = "\(projectRuns.count) run\(projectRuns.count == 1 ? "" : "s")"
        let terminalText = "\(dashboardTerminalCommands.count) log\(dashboardTerminalCommands.count == 1 ? "" : "s")"
        if summary.pendingApprovalCount > 0 {
            return "\(runText) · \(terminalText) · \(summary.pendingApprovalCount) approval"
        }
        if summary.failureCount > 0 {
            return "\(runText) · \(terminalText) · \(summary.failureCount) issue\(summary.failureCount == 1 ? "" : "s")"
        }
        return "\(runText) · \(terminalText)"
    }

    private var projectOSAttentionText: String {
        if runtimeStatus.tone == .approval { return "Approve or reject the pending tool request." }
        if runtimeStatus.tone == .paused { return "Resume the interrupted run when ready." }
        if runtimeStatus.tone == .error { return runtimeStatus.detail }
        if !summary.blocker.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return summary.blocker }
        if autoContinueState.state == .blocked { return autoContinueState.detail }
        if summary.pendingApprovalCount > 0 { return "\(summary.pendingApprovalCount) approval waiting." }
        if summary.failureCount > 0 { return "\(summary.failureCount) issue needs review." }
        if autoContinueState.isCountingDown { return "Auto-continue starts in \(autoContinueState.remainingSeconds)s." }
        return "No blocker recorded."
    }

    private var projectOSAttentionSymbol: String {
        if runtimeStatus.tone == .approval || summary.pendingApprovalCount > 0 { return "checkmark.shield.fill" }
        if runtimeStatus.tone == .paused { return "pause.circle.fill" }
        if runtimeStatus.tone == .error || !summary.blocker.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || summary.failureCount > 0 { return "exclamationmark.triangle.fill" }
        if autoContinueState.state == .blocked { return "hand.raised.fill" }
        if autoContinueState.isCountingDown { return "timer" }
        return "checkmark.circle.fill"
    }

    private var projectOSAttentionTint: Color {
        if runtimeStatus.tone == .approval || summary.pendingApprovalCount > 0 { return AgentPalette.cyan }
        if runtimeStatus.tone == .paused { return AgentPalette.lilac }
        if runtimeStatus.tone == .error || !summary.blocker.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || summary.failureCount > 0 { return AgentPalette.rose }
        if autoContinueState.state == .blocked { return AgentPalette.rose }
        if autoContinueState.isCountingDown { return AgentPalette.green }
        return AgentPalette.green
    }

    private var projectOSChangedText: String {
        let spine = summary.workflowSpine
        if spine.changedTitle == "No project changes yet" { return spine.changedDetail }
        return "\(spine.changedTitle): \(spine.changedDetail)"
    }

    private var projectOSMissionText: String {
        let runMission = activeProjectOSRun?.mission.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !runMission.isEmpty { return runMission }
        return missionCopy
    }

    private var projectOSCurrentActionText: String {
        if !adaptiveIntent.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return adaptiveIntent.summary
        }
        if let run = activeProjectOSRun,
           !run.currentAction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return run.currentAction
        }
        if runtimeStatus.isVisible { return runtimeStatus.title }
        return projectOSCurrentStep?.title ?? "Waiting for the next mission"
    }

    private var projectOSCurrentReasonText: String {
        if !adaptiveIntent.reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return adaptiveIntent.reason
        }
        if let run = activeProjectOSRun {
            if !run.waitingReason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return run.waitingReason }
            if !run.blockerReason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return run.blockerReason }
            if !run.failureReason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return run.failureReason }
            if !run.latestEventDetail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return run.latestEventDetail }
        }
        if runtimeStatus.isVisible { return runtimeStatus.detail }
        return projectOSCurrentStep?.reason ?? nextStepReason
    }

    private var projectOSCurrentCommandText: String {
        if !adaptiveIntent.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return adaptiveIntent.command
        }
        if !adaptiveIntent.toolName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return adaptiveIntent.toolName
        }
        if let command = activeProjectOSRun?.currentCommand.trimmingCharacters(in: .whitespacesAndNewlines),
           !command.isEmpty {
            return command
        }
        if runtimeStatus.isVisible { return runtimeStatus.changedText ?? runtimeStatus.title }
        return ""
    }

    private var projectOSNextStepText: String {
        if let next = projectOSNextStep?.title, !next.isEmpty { return next }
        if let runNext = activeProjectOSRun?.nextStep.trimmingCharacters(in: .whitespacesAndNewlines),
           !runNext.isEmpty {
            return runNext
        }
        return summary.workflowSpine.nextActionDetail
    }

    private var projectOSProofText: String {
        if let proof = activeProjectOSRun?.proofSummary.trimmingCharacters(in: .whitespacesAndNewlines),
           !proof.isEmpty {
            return proof
        }
        if let artifact = activeProjectOSRun?.artifactsSummary.trimmingCharacters(in: .whitespacesAndNewlines),
           !artifact.isEmpty {
            return artifact
        }
        let spine = summary.workflowSpine
        if spine.proofTitle == "No proof captured yet" || spine.proofTitle == spine.proofDetail {
            return spine.proofDetail
        }
        return "\(spine.proofTitle): \(spine.proofDetail)"
    }

    private var projectOSBlockerTitle: String {
        if autoContinueState.state == .blocked { return "Local Model / Auto-continue" }
        switch projectOSStatus {
        case .waiting: return "Waiting"
        case .blocked, .failed: return "Blocker"
        case .stopped: return "Stopped"
        default: return "Blockers"
        }
    }

    private var projectOSBlockerText: String {
        if let run = activeProjectOSRun {
            if !run.waitingReason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return run.waitingReason }
            if !run.failureReason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return run.failureReason }
            if !run.blockerReason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return run.blockerReason }
            if !run.resumeState.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return run.resumeState }
        }
        if !summary.blocker.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return summary.blocker }
        if autoContinueState.state == .blocked { return autoContinueState.detail }
        if summary.pendingApprovalCount > 0 { return "Review the pending approval before continuing." }
        return summary.workflowSpine.blockerDetail
    }

    private var projectOSBlockerSymbol: String {
        if autoContinueState.state == .blocked { return "hand.raised.fill" }
        switch projectOSStatus {
        case .waiting: return "hourglass"
        case .blocked, .failed: return "exclamationmark.triangle.fill"
        case .stopped: return "pause.circle.fill"
        default: return "checkmark.circle.fill"
        }
    }

    private var projectOSBlockerTint: Color {
        if autoContinueState.state == .blocked { return AgentPalette.rose }
        switch projectOSStatus {
        case .waiting: return AgentPalette.cyan
        case .blocked, .failed: return AgentPalette.rose
        case .stopped: return AgentPalette.lilac
        default: return AgentPalette.green
        }
    }

    private func projectOSTint(for status: ProjectOSRunStatus) -> Color {
        switch status {
        case .idle: return AgentPalette.cyan
        case .planning: return AgentPalette.lilac
        case .running: return AgentPalette.green
        case .waiting: return AgentPalette.cyan
        case .blocked, .failed: return AgentPalette.rose
        case .completed: return AgentPalette.green
        case .stopped: return AgentPalette.lilac
        }
    }

    private func dashboardExecutionTint(_ state: DashboardExecutionState) -> Color {
        switch state {
        case .idle, .waiting, .approvalRequired:
            return AgentPalette.cyan
        case .planning, .resumed:
            return AgentPalette.lilac
        case .running, .succeeded, .proofReady:
            return AgentPalette.green
        case .blocked, .failed:
            return AgentPalette.rose
        }
    }

    private func projectOSIntentTint(_ mode: ProjectOSIntentMode) -> Color {
        switch mode {
        case .idle, .readingContext, .inspectingFiles, .runningCommand, .capturingScreenshot, .waitingApproval:
            return AgentPalette.cyan
        case .planning, .runningTool, .stoppedResumable:
            return AgentPalette.lilac
        case .editingCode, .runningTests, .verifyingOutput, .producingProof, .summarizingCompletion, .completedProof:
            return AgentPalette.green
        case .blocked:
            return AgentPalette.rose
        }
    }

    private func projectOSIntentSymbol(_ mode: ProjectOSIntentMode) -> String {
        switch mode {
        case .idle: return "target"
        case .planning: return "list.bullet.clipboard.fill"
        case .readingContext: return "doc.text.magnifyingglass"
        case .inspectingFiles: return "text.viewfinder"
        case .editingCode: return "doc.badge.gearshape.fill"
        case .runningTool: return "wrench.and.screwdriver.fill"
        case .runningCommand: return "terminal.fill"
        case .runningTests: return "checkmark.shield.fill"
        case .waitingApproval: return "checkmark.shield.fill"
        case .blocked: return "exclamationmark.triangle.fill"
        case .verifyingOutput: return "checkmark.seal.fill"
        case .capturingScreenshot: return "camera.viewfinder"
        case .producingProof: return "shippingbox.fill"
        case .summarizingCompletion: return "text.badge.checkmark"
        case .completedProof: return "checkmark.seal.fill"
        case .stoppedResumable: return "pause.circle.fill"
        }
    }

    private func projectOSIntentObjectSymbol(_ kind: ProjectOSWorkObjectKind) -> String {
        switch kind {
        case .none: return "circle.dashed"
        case .project: return "scope"
        case .step: return "point.3.connected.trianglepath.dotted"
        case .file: return "doc.text.fill"
        case .command: return "terminal.fill"
        case .tool: return "wrench.and.screwdriver.fill"
        case .testBuildGate: return "checkmark.shield.fill"
        case .artifact: return "shippingbox.fill"
        case .approval: return "checkmark.shield.fill"
        case .blocker: return "exclamationmark.triangle.fill"
        case .proof: return "checkmark.seal.fill"
        }
    }

    private func projectOSIntentObjectValue(_ intent: ProjectOSIntentSnapshot) -> String {
        if !intent.filePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return intent.filePath }
        if !intent.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return intent.command }
        if !intent.toolName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return intent.toolName }
        if !intent.testBuildGate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return intent.testBuildGate }
        if !intent.artifactPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return intent.artifactPath }
        if !intent.blocker.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return intent.blocker }
        if !intent.proof.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return intent.proof }
        if !intent.objectDetail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return intent.objectDetail }
        return intent.objectTitle
    }

    private func projectOSStatusSymbol(for status: ProjectOSRunStatus) -> String {
        switch status {
        case .idle: return "target"
        case .planning: return "list.bullet.clipboard.fill"
        case .running: return "waveform"
        case .waiting: return "hourglass"
        case .blocked: return "exclamationmark.triangle.fill"
        case .failed: return "xmark.octagon.fill"
        case .completed: return "checkmark.seal.fill"
        case .stopped: return "pause.circle.fill"
        }
    }

    private func projectOSStepTint(_ status: ProjectOSStepStatus) -> Color {
        switch status {
        case .pending: return AgentPalette.tertiaryText
        case .planning: return AgentPalette.lilac
        case .running: return AgentPalette.green
        case .waiting: return AgentPalette.cyan
        case .blocked, .failed: return AgentPalette.rose
        case .completed: return AgentPalette.green
        case .skipped, .stopped: return AgentPalette.lilac
        }
    }

    private func projectOSStepSymbol(_ key: String) -> String {
        switch key {
        case "context": return "doc.text.magnifyingglass"
        case "plan", "draft-plan": return "list.bullet.clipboard.fill"
        case "choose": return "arrow.triangle.branch"
        case "execute": return "hammer.fill"
        case "save-direction": return "tray.and.arrow.down.fill"
        case "verify": return "checkmark.shield.fill"
        case "risks": return "exclamationmark.magnifyingglass"
        case "inspect-artifact": return "shippingbox.fill"
        case "polish": return "wand.and.stars"
        case "inspect-blocker": return "exclamationmark.triangle.fill"
        case "repair": return "wrench.adjustable.fill"
        case "review-evidence": return "text.viewfinder"
        case "recommend": return "lightbulb.fill"
        case "proof": return "checkmark.seal.fill"
        default: return "circle.dotted"
        }
    }

    private var projectPinnedCommandCenter: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: statusSymbol)
                    .font(.system(size: 14, weight: .black))
                    .foregroundStyle(statusTint)
                    .frame(width: 34, height: 34)
                    .background(statusTint.opacity(0.12), in: RoundedRectangle(cornerRadius: 11, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    Text(project.name)
                        .font(.system(size: 15.5, weight: .black, design: AgentPalette.interfaceFontDesign))
                        .foregroundStyle(AgentPalette.ink)
                        .lineLimit(2)
                        .minimumScaleFactor(0.78)
                        .truncationMode(.tail)
                    Text("\(project.workspaceName) · \(summary.statusText)")
                        .font(.system(size: 9.5, weight: .black, design: AgentPalette.interfaceFontDesign))
                        .foregroundStyle(AgentPalette.secondaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .layoutPriority(1)

                Spacer(minLength: 0)

                Button {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    showsProjectSwitcherSheet = true
                } label: {
                    Image(systemName: "rectangle.stack.fill")
                        .font(.system(size: 14, weight: .black))
                        .foregroundStyle(AgentPalette.cyan)
                        .frame(width: AgentDesign.minimumTouchTarget, height: AgentDesign.minimumTouchTarget)
                }
                .buttonStyle(.plain)
                .agentControlSurface(radius: 13, tint: AgentPalette.cyan.opacity(0.10), selected: false)
                .accessibilityLabel("Open projects")
                .accessibilityIdentifier("projectPinnedSwitcherButton")

                Menu {
                    Button {
                        showsProjectEditSheet = true
                    } label: {
                        Label("Edit Project", systemImage: "pencil")
                    }
                    Button(role: .destructive) {
                        confirmingProjectDelete = true
                    } label: {
                        Label("Delete Project", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 14, weight: .black))
                        .foregroundStyle(AgentPalette.secondaryText)
                        .frame(width: AgentDesign.minimumTouchTarget, height: AgentDesign.minimumTouchTarget)
                }
                .buttonStyle(.plain)
                .agentControlSurface(radius: 13, tint: AgentPalette.lilac.opacity(0.08), selected: false)
                .accessibilityLabel("Project actions")
                .accessibilityIdentifier("projectPinnedActionsMenu")
            }

            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(pinnedRunEyebrow)
                        .font(.system(size: 8.5, weight: .black, design: AgentPalette.interfaceFontDesign))
                        .foregroundStyle(pinnedRunTint)
                        .textCase(.uppercase)
                    Text(pinnedRunDetail)
                        .font(.system(size: 10.5, weight: .semibold, design: AgentPalette.interfaceFontDesign))
                        .foregroundStyle(AgentPalette.secondaryText)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("projectPinnedRunReason")
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Button {
                    handlePinnedRunButton()
                } label: {
                    Label(pinnedRunButtonTitle, systemImage: pinnedRunButtonSymbol)
                        .font(.system(size: 12, weight: .black, design: AgentPalette.interfaceFontDesign))
                        .frame(minWidth: 104, minHeight: AgentDesign.minimumTouchTarget)
                }
                .buttonStyle(ProjectRunButtonStyle(tint: pinnedRunTint, isDisabled: pinnedRunButtonDisabled))
                .disabled(pinnedRunButtonDisabled)
                .accessibilityHint(pinnedRunButtonDisabled ? pinnedRunDisabledReason : pinnedRunAccessibilityHint)
                .accessibilityIdentifier("projectPinnedRunButton")
            }
        }
        .padding(12)
        .agentGlass(radius: 22, interactive: false, tint: pinnedRunTint.opacity(0.12))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(pinnedRunTint.opacity(0.18), lineWidth: 0.65)
        )
        .accessibilityIdentifier("projectPinnedCommandCenter")
    }

    private func handlePinnedRunButton() {
        if runtimeStatus.tone == .working {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            stopWorkspaceRun()
            return
        }
        if runtimeStatus.tone == .approval {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            approvePendingTool()
            return
        }
        guard !pinnedRunButtonDisabled else { return }
        runStartFeedback = true
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        runProjectCommand(project, recommendedCommandIntent, trimmedCommandContext)
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(1_000))
            runStartFeedback = false
        }
    }

    private var pinnedRunEyebrow: String {
        if runStartFeedback { return "Starting" }
        if runtimeStatus.tone == .working { return "Running" }
        if runtimeStatus.tone == .approval { return "Approval Needed" }
        if runtimeStatus.tone == .paused { return "Resume Ready" }
        if runtimeStatus.tone == .error { return "Recovery" }
        if projectOSStatus == .blocked || projectOSStatus == .failed { return "Blocked" }
        if projectOSStatus == .completed { return "Proof Ready" }
        if commandRunBlocked { return "Unavailable" }
        return "Next Run"
    }

    private var pinnedRunDetail: String {
        if runStartFeedback { return "NovaForge is opening the project run now." }
        if runtimeStatus.tone == .approval { return "Review the pending request. Approve here, or reject from the approval panel below." }
        if runtimeStatus.tone == .paused { return runtimeStatus.detail }
        if runtimeStatus.tone == .error { return runtimeStatus.detail }
        if runtimeStatus.isVisible { return runtimeStatus.detail }
        if projectOSStatus == .blocked || projectOSStatus == .failed { return projectOSBlockerText }
        if projectOSStatus == .completed { return projectOSProofText }
        if commandRunBlocked { return pinnedRunDisabledReason }
        return nextStepReason
    }

    private var pinnedRunButtonTitle: String {
        if runStartFeedback { return "Starting" }
        if runtimeStatus.tone == .working { return "Stop" }
        if runtimeStatus.tone == .approval { return "Approve" }
        if runtimeStatus.tone == .paused { return "Resume" }
        if runtimeStatus.tone == .error { return "Retry" }
        if projectOSStatus == .blocked || projectOSStatus == .failed { return "Recover" }
        return "Run"
    }

    private var pinnedRunButtonSymbol: String {
        if runStartFeedback { return "hourglass" }
        if runtimeStatus.tone == .working { return "stop.fill" }
        if runtimeStatus.tone == .approval { return "checkmark.shield.fill" }
        if runtimeStatus.tone == .paused { return "play.fill" }
        if runtimeStatus.tone == .error { return "arrow.clockwise" }
        if projectOSStatus == .blocked || projectOSStatus == .failed { return "wrench.and.screwdriver.fill" }
        return "play.fill"
    }

    private var pinnedRunTint: Color {
        if runtimeStatus.tone == .working { return AgentPalette.rose }
        if runtimeStatus.tone == .approval { return AgentPalette.cyan }
        if runtimeStatus.tone == .paused { return AgentPalette.lilac }
        if runtimeStatus.tone == .error { return AgentPalette.rose }
        if runStartFeedback { return AgentPalette.green }
        if projectOSStatus == .blocked || projectOSStatus == .failed { return AgentPalette.rose }
        if projectOSStatus == .completed { return AgentPalette.green }
        return commandTint(for: recommendedCommandIntent)
    }

    private var pinnedRunButtonDisabled: Bool {
        if runtimeStatus.tone == .working { return false }
        if runtimeStatus.tone == .approval { return false }
        return commandRunBlocked
    }

    private var pinnedRunDisabledReason: String {
        switch runtimeStatus.tone {
        case .approval:
            return "Review the pending approval before starting another command."
        case .working:
            return "The current run can be stopped from here."
        default:
            return runtimeStatus.detail
        }
    }

    private var pinnedRunAccessibilityHint: String {
        if runtimeStatus.tone == .approval { return "Approve the pending project tool request." }
        if runtimeStatus.tone == .working { return "Stop the current workspace run." }
        if runtimeStatus.tone == .paused { return "Resume the interrupted project run." }
        if runtimeStatus.tone == .error { return "Retry the recommended recovery step." }
        if projectOSStatus == .blocked || projectOSStatus == .failed { return "Start a recovery run for the active blocker." }
        return recommendedCommandIntent.instructionFocus
    }

    private var projectHeroCard: some View {
        let _ = AgentPerformance.bodyEvaluation("Project Hero Body")
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(project.workspaceName)
                        .font(.system(size: 10, weight: .black, design: AgentPalette.interfaceFontDesign))
                        .foregroundStyle(AgentPalette.tertiaryText)
                        .lineLimit(1)
                        .textCase(.uppercase)

                    Text(project.name)
                        .font(.system(size: 26, weight: .black, design: AgentPalette.interfaceFontDesign))
                        .foregroundStyle(AgentPalette.ink)
                        .lineLimit(1)
                        .minimumScaleFactor(0.64)
                        .accessibilityIdentifier("projectActiveName")
                }
                .layoutPriority(1)

                Spacer(minLength: 0)
                statusBadge

                Button {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    showsProjectSwitcherSheet = true
                } label: {
                    Image(systemName: "rectangle.stack.fill")
                        .font(.system(size: 16, weight: .black))
                        .foregroundStyle(AgentPalette.primaryAccent)
                        .frame(width: 42, height: 42)
                }
                .buttonStyle(.plain)
                .frame(width: AgentDesign.minimumTouchTarget, height: AgentDesign.minimumTouchTarget)
                .contentShape(Rectangle())
                .agentGlass(radius: 15, interactive: true, tint: AgentPalette.primaryAccent.opacity(0.14))
                .glassIDIfAvailable("project-switcher-button", namespace: projectSwitchGlassNamespace)
                .accessibilityLabel("Open projects")
                .accessibilityIdentifier("projectSwitcherSheetButton")
            }

            projectMissionBrief
            if runtimeStatus.isVisible {
                projectCompactRunStatusPanel
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
            projectReviewDashboard
            projectPlanPreviewPanel
            projectEvidenceRailPanel
            projectAtAGlanceGrid
        }
        .padding(14)
        .agentGlass(radius: 24, interactive: false, tint: statusTint.opacity(0.14))
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(statusTint.opacity(0.22), lineWidth: 0.7)
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("projectHeroCard")
    }

    private struct ProjectAtAGlanceItem: Identifiable {
        let id: String
        let title: String
        let value: String
        let symbol: String
        let tint: Color
    }

    private var projectMissionBrief: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "scope")
                .font(.system(size: 11, weight: .black))
                .foregroundStyle(AgentPalette.cyan)
                .frame(width: 26, height: 26)
                .background(AgentPalette.cyan.opacity(0.10), in: RoundedRectangle(cornerRadius: 9, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text("Mission")
                    .font(.system(size: 8.5, weight: .black, design: AgentPalette.interfaceFontDesign))
                    .foregroundStyle(AgentPalette.tertiaryText)
                    .textCase(.uppercase)
                Text(missionCopy)
                    .font(.system(size: 11.5, weight: .semibold, design: AgentPalette.interfaceFontDesign))
                    .foregroundStyle(AgentPalette.secondaryText)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("projectMissionValue")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(AgentPalette.row.opacity(0.52), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("projectMissionBrief")
    }

    private var projectCompactRunStatusPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: runtimeStatus.symbol)
                    .font(.system(size: 11, weight: .black))
                    .foregroundStyle(runtimeStatus.tint)
                    .frame(width: 26, height: 26)
                    .background(runtimeStatus.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 9, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    Text(runtimeStatus.title)
                        .font(.system(size: 12, weight: .black, design: AgentPalette.interfaceFontDesign))
                        .foregroundStyle(AgentPalette.ink)
                        .lineLimit(1)
                    Text(runtimeStatus.detail)
                        .font(.system(size: 10, weight: .semibold, design: AgentPalette.interfaceFontDesign))
                        .foregroundStyle(AgentPalette.secondaryText)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)
            }

            if !runtimeStatus.progressSteps.isEmpty {
                VStack(spacing: 5) {
                    ForEach(runtimeStatus.progressSteps.prefix(3)) { step in
                        compactRunStepRow(step)
                    }
                }
            }
        }
        .padding(10)
        .background(runtimeStatus.tint.opacity(0.075), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .strokeBorder(runtimeStatus.tint.opacity(0.18), lineWidth: 0.55)
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("projectCompactRunStatusPanel")
    }

    private func compactRunStepRow(_ step: WorkspaceProgressStep) -> some View {
        let tint = liveProgressTint(for: step.state)
        return HStack(spacing: 7) {
            Image(systemName: liveProgressSymbol(for: step))
                .font(.system(size: 8.5, weight: .black))
                .foregroundStyle(tint)
                .frame(width: 19, height: 19)
                .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 7, style: .continuous))

            Text(step.title)
                .font(.system(size: 9.5, weight: .black, design: AgentPalette.interfaceFontDesign))
                .foregroundStyle(AgentPalette.ink)
                .lineLimit(1)

            Spacer(minLength: 0)

            Text(liveProgressStateLabel(step.state))
                .font(.system(size: 7.5, weight: .black, design: AgentPalette.interfaceFontDesign))
                .foregroundStyle(tint)
                .lineLimit(1)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
        .background(AgentPalette.row.opacity(0.42), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(step.title), \(liveProgressStateLabel(step.state))")
    }

    private var projectReviewDashboard: some View {
        let review = summary.review
        let tint = self.reviewTint(for: review.recommendation)
        return VStack(alignment: .leading, spacing: 11) {
            HStack(alignment: .center, spacing: 12) {
                projectReviewScoreGauge(score: review.healthScore, tint: tint)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 7) {
                        Label(review.recommendation.displayName, systemImage: review.recommendation.symbolName)
                            .font(.system(size: 9.5, weight: .black, design: AgentPalette.interfaceFontDesign))
                            .foregroundStyle(tint)
                            .lineLimit(1)
                            .padding(.horizontal, 8)
                            .frame(height: 22)
                            .background(tint.opacity(0.10), in: Capsule(style: .continuous))
                        Text(review.proofFreshness)
                            .font(.system(size: 9, weight: .black, design: AgentPalette.interfaceFontDesign))
                            .foregroundStyle(self.proofFreshnessTint)
                            .lineLimit(1)
                    }

                    Text(review.headline)
                        .font(.system(size: 14.5, weight: .black, design: AgentPalette.interfaceFontDesign))
                        .foregroundStyle(AgentPalette.ink)
                        .lineLimit(2)
                        .minimumScaleFactor(0.82)
                        .accessibilityIdentifier("projectReviewHeadline")

                    Text(review.detail)
                        .font(.system(size: 10.5, weight: .semibold, design: AgentPalette.interfaceFontDesign))
                        .foregroundStyle(AgentPalette.secondaryText)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("projectReviewDetail")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            VStack(spacing: 6) {
                ForEach(Array(review.findings.prefix(3))) { finding in
                    projectReviewFindingRow(finding, compact: true)
                }
            }
        }
        .padding(11)
        .background(
            LinearGradient(
                colors: [
                    tint.opacity(0.12),
                    AgentPalette.row.opacity(0.62),
                    AgentPalette.surfaceAlt.opacity(0.25)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 17, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 17, style: .continuous)
                .strokeBorder(tint.opacity(0.20), lineWidth: 0.65)
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("projectReviewDashboard")
    }

    private func projectReviewScoreGauge(score: Int, tint: Color) -> some View {
        ZStack {
            Circle()
                .stroke(AgentPalette.border.opacity(0.26), lineWidth: 5)
            Circle()
                .trim(from: 0, to: CGFloat(max(0, min(score, 100))) / 100)
                .stroke(tint, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: 0) {
                Text("\(score)")
                    .font(.system(size: 17, weight: .black, design: AgentPalette.interfaceFontDesign))
                    .foregroundStyle(tint)
                    .monospacedDigit()
                Text("health")
                    .font(.system(size: 6.8, weight: .black, design: AgentPalette.interfaceFontDesign))
                    .foregroundStyle(AgentPalette.tertiaryText)
                    .textCase(.uppercase)
            }
        }
        .frame(width: 56, height: 56)
        .accessibilityLabel("Project health \(score) percent")
    }

    private func projectReviewFindingRow(_ finding: ProjectReviewFinding, compact: Bool) -> some View {
        let tint = self.reviewFindingTint(finding.severity)
        return HStack(alignment: .top, spacing: 8) {
            Image(systemName: finding.symbolName)
                .font(.system(size: compact ? 9 : 11, weight: .black))
                .foregroundStyle(tint)
                .frame(width: compact ? 20 : 26, height: compact ? 20 : 26)
                .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: compact ? 7 : 9, style: .continuous))

            VStack(alignment: .leading, spacing: compact ? 1 : 2) {
                Text(finding.title)
                    .font(.system(size: compact ? 9.5 : 11.5, weight: .black, design: AgentPalette.interfaceFontDesign))
                    .foregroundStyle(AgentPalette.ink)
                    .lineLimit(1)
                Text(finding.detail)
                    .font(.system(size: compact ? 9 : 10, weight: .semibold, design: AgentPalette.interfaceFontDesign))
                    .foregroundStyle(AgentPalette.secondaryText)
                    .lineLimit(compact ? 1 : 2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, compact ? 7 : 9)
        .padding(.vertical, compact ? 6 : 8)
        .background(tint.opacity(compact ? 0.055 : 0.07), in: RoundedRectangle(cornerRadius: compact ? 11 : 13, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(finding.title). \(finding.detail)")
        .accessibilityIdentifier("projectReviewFinding-\(finding.id)")
    }

    private var projectPlanPreviewPanel: some View {
        let contract = summary.missionContract
        let tint = missionOSTint(for: contract)
        let activeGate = contract.blockingGates.first ?? contract.gates.first { $0.state != .satisfied } ?? contract.gates.last
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Label("Project Plan", systemImage: contract.phase.symbolName)
                    .font(.system(size: 11, weight: .black, design: AgentPalette.interfaceFontDesign))
                    .foregroundStyle(AgentPalette.ink)
                Spacer(minLength: 0)
                Text(contract.gateSummary)
                    .font(.system(size: 9.5, weight: .black, design: AgentPalette.interfaceFontDesign))
                    .foregroundStyle(tint)
                    .lineLimit(1)
            }

            missionPhaseTrack(contract)

            if let activeGate {
                missionPlanActiveRow(activeGate)
            }

            nextActionSignal(
                title: "Why this is next",
                value: nextStepReason,
                symbol: "arrow.triangle.branch",
                tint: commandTint(for: recommendedCommandIntent),
                accessibilityIdentifier: "projectPlanWhyNext"
            )
        }
        .padding(11)
        .background(AgentPalette.row.opacity(0.58), in: RoundedRectangle(cornerRadius: 17, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 17, style: .continuous)
                .strokeBorder(tint.opacity(0.18), lineWidth: 0.6)
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("projectPlanPreviewPanel")
    }

    private func missionPhaseTrack(_ contract: MissionOSContract) -> some View {
        let currentIndex = self.phaseIndex(contract.phase)
        return HStack(spacing: 5) {
            ForEach(MissionOSPhase.allCases, id: \.self) { phase in
                let index = self.phaseIndex(phase)
                let isCurrent = index == currentIndex
                let tint = self.phaseTrackTint(phase, contract: contract)
                VStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(tint.opacity(index <= currentIndex ? 0.92 : 0.20))
                        .frame(height: isCurrent ? 9 : 6)
                    Text(String(phase.displayName.prefix(1)))
                        .font(.system(size: 7.5, weight: .black, design: AgentPalette.interfaceFontDesign))
                        .foregroundStyle(isCurrent ? tint : AgentPalette.tertiaryText)
                }
                .frame(maxWidth: .infinity)
                .accessibilityLabel("\(phase.displayName) \(index < currentIndex ? "complete" : isCurrent ? "current" : "upcoming")")
            }
        }
        .accessibilityIdentifier("projectMissionPhaseTrack")
    }

    private func missionPlanActiveRow(_ gate: MissionOSGate) -> some View {
        let tint = missionOSGateTint(gate.state)
        return HStack(alignment: .top, spacing: 9) {
            Image(systemName: gate.state.symbolName)
                .font(.system(size: 10, weight: .black))
                .foregroundStyle(tint)
                .frame(width: 24, height: 24)
                .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(gate.title)
                        .font(.system(size: 10.5, weight: .black, design: AgentPalette.interfaceFontDesign))
                        .foregroundStyle(AgentPalette.ink)
                        .lineLimit(1)
                    Text(gate.state.displayName)
                        .font(.system(size: 8, weight: .black, design: AgentPalette.interfaceFontDesign))
                        .foregroundStyle(tint)
                        .lineLimit(1)
                }
                Text(gate.detail)
                    .font(.system(size: 9.5, weight: .semibold, design: AgentPalette.interfaceFontDesign))
                    .foregroundStyle(AgentPalette.secondaryText)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(9)
        .background(tint.opacity(0.065), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("projectPlanActiveGate")
    }

    private struct ProjectEvidenceNode: Identifiable {
        let id: String
        let title: String
        let value: String
        let symbol: String
        let state: MissionOSGateState
    }

    private var projectEvidenceRailPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Label("Evidence Trail", systemImage: "checkmark.seal.fill")
                    .font(.system(size: 11, weight: .black, design: AgentPalette.interfaceFontDesign))
                    .foregroundStyle(AgentPalette.ink)
                Spacer(minLength: 0)
                Text(summary.review.evidenceTrail)
                    .font(.system(size: 8.8, weight: .black, design: AgentPalette.interfaceFontDesign))
                    .foregroundStyle(AgentPalette.tertiaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
            }

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 7) {
                ForEach(projectEvidenceNodes) { node in
                    projectEvidenceNodeCell(node)
                }
            }
        }
        .padding(11)
        .background(AgentPalette.surfaceAlt.opacity(0.30), in: RoundedRectangle(cornerRadius: 17, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 17, style: .continuous)
                .strokeBorder(AgentPalette.green.opacity(0.14), lineWidth: 0.55)
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("projectEvidenceRailPanel")
    }

    private var projectEvidenceNodes: [ProjectEvidenceNode] {
        let gates = Dictionary(uniqueKeysWithValues: summary.missionContract.gates.map { ($0.id, $0) })
        return [
            ProjectEvidenceNode(
                id: "contract",
                title: "Goal",
                value: gates["contract"]?.state.displayName ?? "Waiting",
                symbol: "scope",
                state: gates["contract"]?.state ?? .waiting
            ),
            ProjectEvidenceNode(
                id: "action",
                title: "Work",
                value: gates["action"]?.state.displayName ?? "Waiting",
                symbol: "hammer.fill",
                state: gates["action"]?.state ?? .waiting
            ),
            ProjectEvidenceNode(
                id: "verification",
                title: "Check",
                value: gates["verification"]?.state.displayName ?? "Waiting",
                symbol: "checkmark.shield.fill",
                state: gates["verification"]?.state ?? .waiting
            ),
            ProjectEvidenceNode(
                id: "proof",
                title: "Proof",
                value: summary.review.proofFreshness,
                symbol: "checkmark.seal.fill",
                state: gates["proof"]?.state ?? .waiting
            )
        ]
    }

    private func projectEvidenceNodeCell(_ node: ProjectEvidenceNode) -> some View {
        let tint = missionOSGateTint(node.state)
        return HStack(spacing: 7) {
            Image(systemName: node.symbol)
                .font(.system(size: 9.5, weight: .black))
                .foregroundStyle(tint)
                .frame(width: 22, height: 22)
                .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 1) {
                Text(node.title)
                    .font(.system(size: 8, weight: .black, design: AgentPalette.interfaceFontDesign))
                    .foregroundStyle(AgentPalette.tertiaryText)
                    .textCase(.uppercase)
                Text(node.value)
                    .font(.system(size: 9.5, weight: .black, design: AgentPalette.interfaceFontDesign))
                    .foregroundStyle(AgentPalette.secondaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(tint.opacity(0.055), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(node.title): \(node.value)")
        .accessibilityIdentifier("projectEvidenceNode-\(node.id)")
    }

    private var projectAtAGlanceGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
            ForEach(projectAtAGlanceItems) { item in
                projectAtAGlanceCell(item)
            }
        }
        .accessibilityIdentifier("projectCommandCenterSnapshot")
    }

    private var projectAtAGlanceItems: [ProjectAtAGlanceItem] {
        [
            ProjectAtAGlanceItem(
                id: "now",
                title: "Now",
                value: self.currentWorkText,
                symbol: runtimeStatus.isWorking ? "waveform" : statusSymbol,
                tint: runtimeStatus.isVisible ? runtimeStatus.tint : statusTint
            ),
            ProjectAtAGlanceItem(
                id: "last",
                title: "Last",
                value: summary.lastEventTitle,
                symbol: "clock.arrow.circlepath",
                tint: AgentPalette.cyan
            ),
            ProjectAtAGlanceItem(
                id: "proof",
                title: "Proof",
                value: latestProofText,
                symbol: "checkmark.seal.fill",
                tint: trustTint
            ),
            ProjectAtAGlanceItem(
                id: "changed",
                title: "Changed",
                value: self.changedArtifactText,
                symbol: "shippingbox.fill",
                tint: AgentPalette.green
            ),
            ProjectAtAGlanceItem(
                id: "approval",
                title: "Approval",
                value: approvalExpectationText,
                symbol: approvalExpectationSymbol,
                tint: approvalExpectationTint
            ),
            ProjectAtAGlanceItem(
                id: "blocker",
                title: "Blocker",
                value: self.blockerSnapshotText,
                symbol: summary.blocker.isEmpty && summary.failureCount == 0 ? "checkmark.circle.fill" : "exclamationmark.triangle.fill",
                tint: summary.blocker.isEmpty && summary.failureCount == 0 ? AgentPalette.lilac : AgentPalette.rose
            )
        ]
    }

    private func projectAtAGlanceCell(_ item: ProjectAtAGlanceItem) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: item.symbol)
                .font(.system(size: 9, weight: .black))
                .foregroundStyle(item.tint)
                .frame(width: 22, height: 22)
                .background(item.tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 1) {
                Text(item.title)
                    .font(.system(size: 8, weight: .black, design: AgentPalette.interfaceFontDesign))
                    .foregroundStyle(AgentPalette.tertiaryText)
                    .textCase(.uppercase)
                Text(item.value)
                    .font(.system(size: 10, weight: .semibold, design: AgentPalette.interfaceFontDesign))
                    .foregroundStyle(AgentPalette.secondaryText)
                    .lineLimit(2)
                    .minimumScaleFactor(0.82)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .frame(minHeight: 54, alignment: .topLeading)
        .background(AgentPalette.row.opacity(0.46), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(item.title): \(item.value)")
        .accessibilityIdentifier("projectCommandSnapshot-\(item.id)")
    }

    private var projectHeroNextAction: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 11) {
                Image(systemName: commandSymbol(for: recommendedCommandIntent))
                    .font(.system(size: 15, weight: .black))
                    .foregroundStyle(commandTint(for: recommendedCommandIntent))
                    .frame(width: 34, height: 34)
                    .background(
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .fill(commandTint(for: recommendedCommandIntent).opacity(0.12))
                    )

                VStack(alignment: .leading, spacing: 3) {
                    Text("Next Action")
                        .font(.system(size: 9, weight: .black, design: AgentPalette.interfaceFontDesign))
                        .foregroundStyle(AgentPalette.tertiaryText)
                    Text("Agent-chosen step")
                        .font(.system(size: 14, weight: .black, design: AgentPalette.interfaceFontDesign))
                        .foregroundStyle(AgentPalette.ink)
                        .lineLimit(1)
                    Text(summary.nextStep)
                        .font(.system(size: 11, weight: .semibold, design: AgentPalette.interfaceFontDesign))
                        .foregroundStyle(AgentPalette.secondaryText)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("projectNextStepValue")
                }

                Spacer(minLength: 0)
            }

            VStack(spacing: 6) {
                nextActionSignal(
                    title: "Why",
                    value: nextStepReason,
                    symbol: "arrow.triangle.branch",
                    tint: commandTint(for: recommendedCommandIntent),
                    accessibilityIdentifier: "projectNextStepReason"
                )
                nextActionSignal(
                    title: "Proof",
                    value: expectedProofText,
                    symbol: "checkmark.seal.fill",
                    tint: AgentPalette.green,
                    accessibilityIdentifier: "projectExpectedProof"
                )
                nextActionSignal(
                    title: "Approval",
                    value: approvalExpectationText,
                    symbol: approvalExpectationSymbol,
                    tint: approvalExpectationTint,
                    accessibilityIdentifier: "projectApprovalExpectation"
                )
            }

            self.autoContinueControl

            HStack(spacing: 9) {
                Button {
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    runProjectCommand(project, recommendedCommandIntent, trimmedCommandContext)
                } label: {
                    Label(projectRunButtonTitle, systemImage: projectRunButtonSymbol)
                        .font(.system(size: 11.5, weight: .black, design: AgentPalette.interfaceFontDesign))
                        .frame(minWidth: AgentDesign.minimumTouchTarget, maxWidth: .infinity, minHeight: 40)
                }
                .buttonStyle(ProjectRunButtonStyle(tint: projectRunButtonTint, isDisabled: commandRunBlocked))
                .disabled(commandRunBlocked)
                .accessibilityHint(commandRunBlocked ? "Finish the current run before starting another project command." : recommendedCommandIntent.instructionFocus)
                .accessibilityIdentifier("projectHeroRunButton")
            }
        }
        .padding(10)
        .frame(minHeight: 214, alignment: .top)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(AgentPalette.row.opacity(0.64))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(commandTint(for: recommendedCommandIntent).opacity(0.18), lineWidth: 0.55)
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("projectHeroNextAction")
    }

    private func nextActionSignal(
        title: String,
        value: String,
        symbol: String,
        tint: Color,
        accessibilityIdentifier: String
    ) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .black))
                .foregroundStyle(tint)
                .frame(width: 20, height: 20)

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 8.5, weight: .black, design: AgentPalette.interfaceFontDesign))
                    .foregroundStyle(AgentPalette.tertiaryText)
                    .textCase(.uppercase)
                Text(value)
                    .font(.system(size: 10.5, weight: .semibold, design: AgentPalette.interfaceFontDesign))
                    .foregroundStyle(AgentPalette.secondaryText)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 3)
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title): \(value)")
        .accessibilityIdentifier(accessibilityIdentifier)
    }

    private var autoContinueControl: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: Binding(
                get: { autoContinueState.isEnabled },
                set: { setAutoContinueEnabled(project, $0) }
            )) {
                HStack(spacing: 8) {
                    Image(systemName: autoContinueSymbol)
                        .font(.system(size: 10, weight: .black))
                        .foregroundStyle(autoContinueTint)
                        .frame(width: 22, height: 22)
                        .background(autoContinueTint.opacity(0.10), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

                    VStack(alignment: .leading, spacing: 1) {
                        Text("Auto-continue next steps")
                            .font(.system(size: 10.5, weight: .black, design: AgentPalette.interfaceFontDesign))
                            .foregroundStyle(AgentPalette.ink)
                            .lineLimit(1)
                            .minimumScaleFactor(0.82)
                        Text(autoContinueStateLine)
                            .font(.system(size: 9.5, weight: .semibold, design: AgentPalette.interfaceFontDesign))
                            .foregroundStyle(AgentPalette.secondaryText)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .toggleStyle(.switch)
            .tint(autoContinueTint)
            .accessibilityIdentifier("projectAutoContinueToggle")

            if autoContinueState.isCountingDown {
                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 8) {
                        Text("Starts in \(autoContinueState.remainingSeconds)s")
                            .font(.system(size: 10.5, weight: .black, design: AgentPalette.interfaceFontDesign))
                            .foregroundStyle(autoContinueTint)
                            .monospacedDigit()
                        Spacer(minLength: 0)
                        Button {
                            pauseAutoContinue(project)
                        } label: {
                            Label("Pause", systemImage: "pause.fill")
                                .font(.system(size: 9.5, weight: .black, design: AgentPalette.interfaceFontDesign))
                                .frame(minHeight: 30)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(AgentPalette.secondaryText)
                        .accessibilityIdentifier("projectAutoContinuePauseButton")

                        Button {
                            cancelAutoContinue(project)
                        } label: {
                            Label("Cancel", systemImage: "xmark")
                                .font(.system(size: 9.5, weight: .black, design: AgentPalette.interfaceFontDesign))
                                .frame(minHeight: 30)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(AgentPalette.rose)
                        .accessibilityIdentifier("projectAutoContinueCancelButton")
                    }

                    ProgressView(
                        value: Double(ProjectAutoContinuePolicy.countdownSeconds - autoContinueState.remainingSeconds),
                        total: Double(ProjectAutoContinuePolicy.countdownSeconds)
                    )
                    .progressViewStyle(.linear)
                    .tint(autoContinueTint)
                    .frame(height: 6)
                    .clipShape(Capsule())
                    .accessibilityHidden(true)
                }
                .padding(9)
                .background(autoContinueTint.opacity(0.08), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("projectAutoContinueCountdown")
            } else if autoContinueState.isPaused {
                HStack(spacing: 8) {
                    Text(autoContinueState.detail)
                        .font(.system(size: 9.5, weight: .semibold, design: AgentPalette.interfaceFontDesign))
                        .foregroundStyle(AgentPalette.secondaryText)
                        .lineLimit(2)
                    Spacer(minLength: 0)
                    Button {
                        setAutoContinueEnabled(project, true)
                    } label: {
                        Label("Resume", systemImage: "play.fill")
                            .font(.system(size: 9.5, weight: .black, design: AgentPalette.interfaceFontDesign))
                            .frame(minHeight: 30)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(AgentPalette.green)
                    .accessibilityIdentifier("projectAutoContinueResumeButton")
                }
                .padding(9)
                .background(AgentPalette.lilac.opacity(0.08), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                .accessibilityIdentifier("projectAutoContinuePaused")
            }
        }
        .padding(9)
        .background(AgentPalette.surfaceAlt.opacity(0.36), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .strokeBorder(autoContinueTint.opacity(autoContinueState.isEnabled ? 0.18 : 0.10), lineWidth: 0.55)
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("projectAutoContinueControl")
    }

    private var projectRunStatusPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            WorkspaceStatusStrip(
                snapshot: runtimeStatus,
                pause: stopWorkspaceRun,
                destinationSymbol: "list.bullet.rectangle.portrait.fill",
                destinationAccessibilityLabel: "Open run log"
            ) {
                openTab(.runs)
            }

            if !runtimeStatus.progressSteps.isEmpty {
                projectLiveProgressPanel
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("projectRunStatusPanel")
    }

    private var projectLiveProgressPanel: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                Image(systemName: "checklist")
                    .font(.system(size: 11, weight: .black))
                    .foregroundStyle(runtimeStatus.tint)
                    .frame(width: 24, height: 24)
                    .background(runtimeStatus.tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

                Text("Run Progress")
                    .font(.system(size: 11, weight: .black, design: AgentPalette.interfaceFontDesign))
                    .foregroundStyle(AgentPalette.ink)

                Spacer(minLength: 0)

                Text(runtimeStatus.progressSteps.filter { $0.state == .done }.count.description)
                    .font(.system(size: 10, weight: .black, design: AgentPalette.interfaceFontDesign))
                    .monospacedDigit()
                    .foregroundStyle(runtimeStatus.tint)
                    .frame(minWidth: 24, minHeight: 22)
                    .background(runtimeStatus.tint.opacity(0.10), in: Capsule(style: .continuous))
            }

            VStack(spacing: 0) {
                ForEach(Array(runtimeStatus.progressSteps.prefix(7).enumerated()), id: \.element.id) { index, step in
                    liveProgressRow(step, isLast: index == min(runtimeStatus.progressSteps.count, 7) - 1)
                }
            }
            .background(AgentPalette.row.opacity(0.58), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .strokeBorder(runtimeStatus.tint.opacity(0.14), lineWidth: 0.55)
            )
        }
        .padding(11)
        .frame(minHeight: 236, alignment: .top)
        .agentGlass(radius: 18, interactive: false, tint: runtimeStatus.tint.opacity(0.08))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("projectLiveProgressPanel")
    }

    private func liveProgressRow(_ step: WorkspaceProgressStep, isLast: Bool) -> some View {
        let tint = liveProgressTint(for: step.state)
        return VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: liveProgressSymbol(for: step))
                    .font(.system(size: 9.5, weight: .black))
                    .foregroundStyle(tint)
                    .frame(width: 24, height: 24)
                    .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    Text(step.title)
                        .font(.system(size: 10.5, weight: .black, design: AgentPalette.interfaceFontDesign))
                        .foregroundStyle(AgentPalette.ink)
                        .lineLimit(1)
                    Text(step.detail)
                        .font(.system(size: 9.5, weight: .semibold, design: AgentPalette.interfaceFontDesign))
                        .foregroundStyle(AgentPalette.secondaryText)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)

                Text(liveProgressStateLabel(step.state))
                    .font(.system(size: 8, weight: .black, design: AgentPalette.interfaceFontDesign))
                    .foregroundStyle(tint)
                    .padding(.horizontal, 6)
                    .frame(height: 19)
                    .background(tint.opacity(0.10), in: Capsule(style: .continuous))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(step.title). \(liveProgressStateLabel(step.state)). \(step.detail)")
            .accessibilityIdentifier("projectLiveProgressStep-\(step.id)")

            if !isLast {
                Divider()
                    .overlay(AgentPalette.border.opacity(0.34))
                    .padding(.leading, 43)
            }
        }
    }

    @ViewBuilder
    private var latestEvidenceSection: some View {
        let _ = AgentPerformance.bodyEvaluation("Project Latest Evidence Body")
        sectionShell(
            title: latestEvidenceTitle,
            subtitle: latestEvidenceSubtitle,
            symbol: latestEvidenceSymbol,
            tint: latestEvidenceTint
        ) {
            if let artifact = latestEvidenceArtifact {
                artifactFeatureCard(artifact)
            } else if let proof = latestEvidenceProof {
                latestProofCard(proof)
            } else {
                emptyState(title: "No proof yet", detail: "Artifacts, completed runs, and file evidence will appear here.", symbol: "checkmark.seal", tint: AgentPalette.green)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("projectLatestEvidenceSection")
    }

    private var latestEvidenceTitle: String {
        latestEvidenceArtifact == nil ? "Latest Proof" : "Latest Artifact"
    }

    private var latestEvidenceSubtitle: String {
        if let artifact = latestEvidenceArtifact {
            return eventTimeText(artifact.updatedAt)
        }
        if let proof = latestEvidenceProof {
            return eventTimeText(proof.createdAt)
        }
        return "Waiting"
    }

    private var latestEvidenceSymbol: String {
        latestEvidenceArtifact == nil ? "checkmark.seal.fill" : "shippingbox.fill"
    }

    private var latestEvidenceTint: Color {
        if latestEvidenceArtifact != nil { return AgentPalette.cyan }
        if let proof = latestEvidenceProof { return proofTint(for: proof) }
        return AgentPalette.green
    }

    private var latestEvidenceProof: ProjectProofItem? {
        summary.proofItems.first
    }

    private var latestEvidenceArtifact: ProjectArtifact? {
        guard let proof = latestEvidenceProof,
              proof.id.hasPrefix("artifact-"),
              let path = proof.sourcePath else {
            return nil
        }
        return projectArtifacts.first { $0.path == path }
    }

    private func latestProofCard(_ item: ProjectProofItem) -> some View {
        let tint = proofTint(for: item)
        return Button {
            openProofItem(item)
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: item.symbolName)
                    .font(.system(size: 17, weight: .black))
                    .foregroundStyle(tint)
                    .frame(width: 42, height: 42)
                    .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 13, style: .continuous))

                VStack(alignment: .leading, spacing: 4) {
                    Text(item.title)
                        .font(.system(size: 15, weight: .black, design: AgentPalette.interfaceFontDesign))
                        .foregroundStyle(AgentPalette.ink)
                        .lineLimit(2)
                        .minimumScaleFactor(0.82)

                    Text(item.detail)
                        .font(.system(size: 11, weight: .semibold, design: AgentPalette.interfaceFontDesign))
                        .foregroundStyle(AgentPalette.secondaryText)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)

                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .black))
                    .foregroundStyle(AgentPalette.tertiaryText)
                    .padding(.top, 5)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
        .agentRowSurface(radius: 18, tint: tint, selected: true)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(item.title). \(item.detail)")
        .accessibilityIdentifier("projectLatestProofCard")
    }

    private var projectMoreSection: some View {
        let expanded = showsProjectDetails
        return VStack(alignment: .leading, spacing: expanded ? 12 : 0) {
            Button {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                withAnimation((reduceMotion || !AgentPerformance.allowsDecorativeMotion) ? nil : .smooth(duration: 0.28)) {
                    showsProjectDetails.toggle()
                }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: showsProjectDetails ? "chevron.up.circle.fill" : "ellipsis.circle.fill")
                        .font(.system(size: 14, weight: .black))
                        .foregroundStyle(AgentPalette.lilac)
                        .frame(width: 28, height: 28)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("More")
                            .font(.system(size: 13, weight: .black, design: AgentPalette.interfaceFontDesign))
                            .foregroundStyle(AgentPalette.ink)
                        if expanded {
                            Text("Gates, metrics, proof, timeline")
                                .font(.system(size: 10, weight: .semibold, design: AgentPalette.interfaceFontDesign))
                                .foregroundStyle(AgentPalette.tertiaryText)
                                .lineLimit(1)
                        }
                    }

                    Spacer(minLength: 0)
                }
                .padding(.horizontal, expanded ? 13 : 6)
                .padding(.vertical, expanded ? 13 : 5)
                .frame(maxWidth: .infinity, minHeight: AgentDesign.minimumTouchTarget, alignment: .leading)
                .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
            .buttonStyle(.plain)
            .projectMoreSurface(expanded: expanded)
            .accessibilityLabel(showsProjectDetails ? "Hide more project details" : "Show more project details")
            .accessibilityIdentifier("projectMoreButton")

            if showsProjectDetails {
                VStack(alignment: .leading, spacing: 14) {
                    projectDetailScopePicker
                    projectDetailScopeContent
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("projectMoreDetails")
            }
        }
    }

    private var projectDetailScopePicker: some View {
        Picker("Project detail scope", selection: $selectedDetailScope) {
            ForEach(ProjectDetailScope.allCases) { scope in
                Label(scope.title, systemImage: scope.symbol)
                    .tag(scope)
            }
        }
        .pickerStyle(.segmented)
        .accessibilityIdentifier("projectDetailScopePicker")
    }

    @ViewBuilder
    private var projectDetailScopeContent: some View {
        switch selectedDetailScope {
        case .review:
            projectReviewSection
            missionOSPanel
            missionOSGateSection
        case .plan:
            projectPlanDeepSection
            projectCommandCenter
        case .evidence:
            latestEvidenceSection
            proofLedgerSection
            artifactsSection
            fileChangesSection
        case .timeline:
            projectSignals
            timelineSection
        }
    }

    private var projectSwitcherSheet: some View {
        ZStack {
            AgentBackground()
                .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .center, spacing: 10) {
                    Label("Projects", systemImage: "rectangle.stack.fill")
                        .font(.system(size: 18, weight: .black, design: AgentPalette.interfaceFontDesign))
                        .foregroundStyle(AgentPalette.ink)

                    Spacer(minLength: 0)

                    Text("\(projects.count)")
                        .font(.system(size: 11, weight: .black, design: AgentPalette.interfaceFontDesign))
                        .foregroundStyle(AgentPalette.primaryAccent)
                        .padding(.horizontal, 9)
                        .frame(height: 26)
                        .background(AgentPalette.primaryAccent.opacity(0.10), in: Capsule(style: .continuous))
                }

                GlassGroup(spacing: 12) {
                    VStack(spacing: 10) {
                        projectSwitcherList
                        projectCreationCard
                    }
                }

                Spacer(minLength: 0)
            }
            .padding(18)
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .accessibilityIdentifier("projectSwitcherSheet")
    }

    private var projectCreationCard: some View {
        HStack(alignment: .center, spacing: 11) {
            Image(systemName: "plus")
                .font(.system(size: 14, weight: .black))
                .foregroundStyle(AgentPalette.primaryAccent)
                .frame(width: 34, height: 34)
                .agentControlSurface(radius: 11, tint: AgentPalette.primaryAccent.opacity(0.12), selected: true)

            VStack(alignment: .leading, spacing: 3) {
                Text("Create Project")
                    .font(.system(size: 13, weight: .black, design: AgentPalette.interfaceFontDesign))
                    .foregroundStyle(AgentPalette.ink)
                Text("Start a separate agent workspace")
                    .font(.system(size: 10, weight: .semibold, design: AgentPalette.interfaceFontDesign))
                    .foregroundStyle(AgentPalette.secondaryText)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            Button {
                createAndDismissProject()
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 14, weight: .black))
                    .foregroundStyle(AgentPalette.ink)
            }
            .buttonStyle(.plain)
            .frame(width: 48, height: 48)
            .contentShape(Rectangle())
            .agentGlass(radius: 14, interactive: true, tint: AgentPalette.primaryAccent.opacity(0.16))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Create Project")
            .accessibilityHint("Start a separate agent workspace.")
            .accessibilityIdentifier("projectNewButton")
        }
        .padding(10)
        .frame(maxWidth: .infinity, minHeight: AgentDesign.minimumTouchTarget, alignment: .leading)
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .agentGlass(radius: 16, interactive: true, tint: AgentPalette.primaryAccent.opacity(0.14))
        .overlay(alignment: .topTrailing) {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(AgentPalette.primaryAccent.opacity(0.18), lineWidth: 0.6)
                .allowsHitTesting(false)
        }
        .shadow(color: AgentPalette.primaryAccent.opacity(0.08), radius: 10, x: 0, y: 5)
        .accessibilityElement(children: .contain)
    }

    private func createAndDismissProject() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        showsProjectSwitcherSheet = false
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 220_000_000)
            showsProjectIntakeSheet = true
        }
    }

    private var projectSwitcherList: some View {
        VStack(spacing: 4) {
            HStack {
                Label("Active projects", systemImage: "sidebar.leading")
                    .font(.system(size: 10, weight: .black, design: AgentPalette.interfaceFontDesign))
                    .foregroundStyle(AgentPalette.secondaryText)
                Spacer(minLength: 0)
                Text("\(projects.count)")
                    .font(.system(size: 10, weight: .black, design: AgentPalette.interfaceFontDesign))
                    .foregroundStyle(AgentPalette.primaryAccent)
                    .padding(.horizontal, 8)
                    .frame(height: 22)
                    .background(AgentPalette.primaryAccent.opacity(0.10), in: Capsule(style: .continuous))
            }
            .padding(.horizontal, 6)
            .padding(.bottom, 2)

            VStack(spacing: 5) {
                ForEach(visibleSwitcherProjects, id: \.id) { candidate in
                    let isSelected = candidate.id == project.id
                    if isSelected {
                        projectSwitcherRow(candidate, isSelected: true)
                            .accessibilityElement(children: .ignore)
                            .accessibilityAddTraits(.isSelected)
                            .accessibilityLabel("Active project, \(candidate.name)")
                            .accessibilityHint("Already selected")
                            .accessibilityIdentifier("projectSwitcherActiveRow")
                    } else {
                        Button {
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            withAnimation((reduceMotion || !AgentPerformance.allowsDecorativeMotion) ? nil : .smooth(duration: 0.42)) {
                                highlightedProjectID = candidate.id
                                selectProject(candidate)
                                showsProjectSwitcherSheet = false
                            }
                        } label: {
                            projectSwitcherRow(candidate, isSelected: false)
                        }
                        .buttonStyle(.plain)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("Open project, \(candidate.name)")
                        .accessibilityHint(projectSwitchDetail(candidate))
                        .accessibilityIdentifier("projectSwitcherRow-\(projectSwitchIdentifier(candidate))")
                    }
                }

                if sortedProjects.count > 4 {
                    Button {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        withAnimation((reduceMotion || !AgentPerformance.allowsDecorativeMotion) ? nil : .smooth(duration: 0.28)) {
                            showsAllProjects.toggle()
                        }
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: showsAllProjects ? "chevron.up.circle.fill" : "ellipsis.circle.fill")
                                .font(.system(size: 12, weight: .black))
                                .foregroundStyle(AgentPalette.primaryAccent)
                            Text(showsAllProjects ? "Show fewer projects" : "Show \(hiddenSwitcherProjectCount) more project\(hiddenSwitcherProjectCount == 1 ? "" : "s")")
                                .font(.system(size: 10.5, weight: .black, design: AgentPalette.interfaceFontDesign))
                                .foregroundStyle(AgentPalette.secondaryText)
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 10)
                        .frame(minHeight: 36)
                        .background(AgentPalette.primaryAccent.opacity(0.07), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(showsAllProjects ? "Show fewer projects" : "Show \(hiddenSwitcherProjectCount) more projects")
                    .accessibilityIdentifier("projectSwitcherMoreButton")
                }
            }
        }
        .padding(8)
        .agentGlass(radius: 20, interactive: false, tint: AgentPalette.primaryAccent.opacity(0.06))
        .animation((reduceMotion || !AgentPerformance.allowsDecorativeMotion) ? nil : .smooth(duration: 0.36), value: project.id)
        .animation((reduceMotion || !AgentPerformance.allowsDecorativeMotion) ? nil : .smooth(duration: 0.28), value: showsAllProjects)
    }

    private func projectSwitcherRow(_ candidate: Project, isSelected: Bool) -> some View {
        let tint = isSelected ? AgentPalette.primaryAccent : AgentPalette.storageAccent
        return HStack(alignment: .center, spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(tint.opacity(isSelected ? 0.14 : 0.08))
                Image(systemName: isSelected ? "checkmark.seal.fill" : "folder.fill")
                    .font(.system(size: 13, weight: .black))
                    .foregroundStyle(tint)
            }
            .frame(width: 34, height: 34)

            VStack(alignment: .leading, spacing: 3) {
                Text(candidate.name)
                    .font(.system(size: 12.5, weight: .black, design: AgentPalette.interfaceFontDesign))
                    .foregroundStyle(AgentPalette.ink)
                    .lineLimit(1)
                    .accessibilityIdentifier(isSelected ? "projectSwitcherActiveName" : "projectSwitcherRowName-\(projectSwitchIdentifier(candidate))")
                Text(projectSwitchDetail(candidate))
                    .font(.system(size: 9.5, weight: .semibold, design: AgentPalette.interfaceFontDesign))
                    .foregroundStyle(AgentPalette.tertiaryText)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            projectSwitcherStateBadge(isSelected: isSelected, projectName: candidate.name)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .frame(minHeight: AgentDesign.minimumTouchTarget)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(isSelected ? AgentPalette.primaryAccent.opacity(0.08) : AgentPalette.surface.opacity(0.34))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(isSelected ? AgentPalette.primaryAccent.opacity(0.20) : AgentPalette.border.opacity(0.10), lineWidth: 0.55)
        )
        .overlay {
            if isSelected && highlightedProjectID == candidate.id {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(AgentPalette.primaryAccent.opacity(0.46), lineWidth: 1.1)
                    .blur(radius: 0.15)
                    .transition(.opacity)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .glassIDIfAvailable("project-switch-\(candidate.id.uuidString)", namespace: projectSwitchGlassNamespace)
        .scaleEffect(isSelected && highlightedProjectID == candidate.id ? 1.01 : 1.0)
        .animation((reduceMotion || !AgentPerformance.allowsDecorativeMotion) ? nil : .smooth(duration: 0.34), value: highlightedProjectID)
    }

    @ViewBuilder
    private func projectSwitcherStateBadge(isSelected: Bool, projectName: String) -> some View {
        let tint = isSelected ? AgentPalette.primaryAccent : AgentPalette.storageAccent
        let badge = Text(isSelected ? "ACTIVE" : "OPEN")
            .font(.system(size: 9, weight: .black, design: AgentPalette.interfaceFontDesign))
            .foregroundStyle(isSelected ? tint : AgentPalette.secondaryText)
            .padding(.horizontal, 8)
            .frame(height: 24)
            .background(
                Capsule(style: .continuous)
                    .fill(tint.opacity(isSelected ? 0.12 : 0.08))
            )

        if isSelected {
            badge
                .accessibilityLabel("Active project, \(projectName)")
                .accessibilityAddTraits(.isSelected)
                .accessibilityIdentifier("projectSwitcherActiveRow")
        } else {
            badge
        }
    }

    private func projectSwitchDetail(_ candidate: Project) -> String {
        let projectID = candidate.id
        let chatCount = conversations.filter { $0.project?.id == projectID }.count
        let artifactCount = candidate.artifacts.count
        return "\(candidate.workspaceName) · \(chatCount) chat\(chatCount == 1 ? "" : "s") · \(artifactCount) artifact\(artifactCount == 1 ? "" : "s")"
    }

    private func projectSwitchIdentifier(_ candidate: Project) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let sanitized = candidate.workspaceName.unicodeScalars
            .map { allowed.contains($0) ? String($0) : "-" }
            .joined()
        return sanitized.isEmpty ? candidate.id.uuidString : sanitized
    }

    private var projectReviewSection: some View {
        let review = summary.review
        let tint = self.reviewTint(for: review.recommendation)
        return sectionShell(
            title: "Project Review",
            subtitle: "\(review.healthScore)% · \(review.recommendation.displayName)",
            symbol: review.recommendation.symbolName,
            tint: tint,
            usesGlass: true
        ) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .center, spacing: 12) {
                    projectReviewScoreGauge(score: review.healthScore, tint: tint)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(review.headline)
                            .font(.system(size: 15, weight: .black, design: AgentPalette.interfaceFontDesign))
                            .foregroundStyle(AgentPalette.ink)
                            .lineLimit(2)
                        Text(review.detail)
                            .font(.system(size: 11, weight: .semibold, design: AgentPalette.interfaceFontDesign))
                            .foregroundStyle(AgentPalette.secondaryText)
                            .lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                HStack(spacing: 8) {
                    missionOSStateBadge(
                        label: "Decision",
                        value: review.recommendation.displayName,
                        symbol: review.recommendation.symbolName,
                        tint: tint
                    )
                    missionOSStateBadge(
                        label: "Proof",
                        value: review.proofFreshness,
                        symbol: "checkmark.seal.fill",
                        tint: self.proofFreshnessTint
                    )
                    missionOSStateBadge(
                        label: "Risks",
                        value: "\(review.riskCount)",
                        symbol: review.riskCount == 0 ? "checkmark.circle.fill" : "exclamationmark.triangle.fill",
                        tint: review.riskCount == 0 ? AgentPalette.green : AgentPalette.rose
                    )
                }

                VStack(spacing: 7) {
                    ForEach(review.findings) { finding in
                        projectReviewFindingRow(finding, compact: false)
                    }
                }
            }
            .accessibilityElement(children: .contain)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("projectReviewSection")
    }

    private var projectPlanDeepSection: some View {
        let contract = summary.missionContract
        let tint = missionOSTint(for: contract)
        return sectionShell(
            title: "Project Plan",
            subtitle: "\(contract.phase.displayName) · \(contract.gateSummary)",
            symbol: contract.phase.symbolName,
            tint: tint
        ) {
            VStack(alignment: .leading, spacing: 12) {
                missionPhaseTrack(contract)

                VStack(alignment: .leading, spacing: 8) {
                    missionSignal(
                        title: "Active step",
                        value: contract.nextAction,
                        symbol: commandSymbol(for: contract.recommendedIntent),
                        tint: commandTint(for: contract.recommendedIntent),
                        accessibilityIdentifier: "projectPlanActiveStep"
                    )
                    missionSignal(
                        title: "Why this is next",
                        value: nextStepReason,
                        symbol: "arrow.triangle.branch",
                        tint: AgentPalette.cyan,
                        accessibilityIdentifier: "projectPlanWhyNextDeep"
                    )
                    missionSignal(
                        title: "Completion rule",
                        value: contract.proofRequirement,
                        symbol: "checkmark.seal.fill",
                        tint: AgentPalette.green,
                        accessibilityIdentifier: "projectPlanCompletionRule"
                    )
                }
                .padding(11)
                .background(AgentPalette.row.opacity(0.62), in: RoundedRectangle(cornerRadius: 16, style: .continuous))

                VStack(alignment: .leading, spacing: 8) {
                    Text("Success Criteria")
                        .font(.system(size: 10, weight: .black, design: AgentPalette.interfaceFontDesign))
                        .foregroundStyle(AgentPalette.tertiaryText)
                        .textCase(.uppercase)

                    ForEach(Array(contract.successCriteria.enumerated()), id: \.offset) { index, criterion in
                        HStack(alignment: .top, spacing: 8) {
                            Text("\(index + 1)")
                                .font(.system(size: 9, weight: .black, design: AgentPalette.interfaceFontDesign))
                                .foregroundStyle(tint)
                                .frame(width: 20, height: 20)
                                .background(tint.opacity(0.10), in: Circle())
                            Text(criterion)
                                .font(.system(size: 10.5, weight: .semibold, design: AgentPalette.interfaceFontDesign))
                                .foregroundStyle(AgentPalette.secondaryText)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                        }
                    }
                }
                .padding(11)
                .background(AgentPalette.surfaceAlt.opacity(0.30), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .accessibilityElement(children: .contain)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("projectPlanDeepSection")
    }

    private var projectSpinePanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 10) {
                Label("Active Project", systemImage: "target")
                    .font(.system(size: 14, weight: .black, design: AgentPalette.interfaceFontDesign))
                    .foregroundStyle(AgentPalette.ink)
                Spacer(minLength: 0)
                statusBadge
            }

            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    Circle()
                        .fill(statusTint.opacity(0.16))
                    Circle()
                        .stroke(statusTint.opacity(0.34), lineWidth: 1)
                    Image(systemName: statusSymbol)
                        .font(.system(size: 22, weight: .black))
                        .foregroundStyle(statusTint)
                }
                .frame(width: 58, height: 58)

                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 7) {
                        miniBadge(title: "Current state", symbol: "gauge.with.dots.needle.bottom.50percent", tint: statusTint)
                        miniBadge(title: project.workspaceName, symbol: "folder.fill", tint: AgentPalette.cyan)
                    }

                    Text(project.name)
                        .font(.system(size: 29, weight: .black, design: AgentPalette.interfaceFontDesign))
                        .foregroundStyle(AgentPalette.ink)
                        .lineLimit(2)
                        .minimumScaleFactor(0.72)
                        .accessibilityIdentifier("projectActiveName")

                    Text(missionCopy)
                        .font(.system(size: 13, weight: .semibold, design: AgentPalette.interfaceFontDesign))
                        .foregroundStyle(AgentPalette.secondaryText)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack(spacing: 10) {
                spineDatum(title: "Trust", value: summary.trustText, symbol: "checkmark.shield.fill", tint: trustTint)
                spineDatum(title: "Last Activity", value: lastActivityText, symbol: "clock.fill", tint: AgentPalette.green)
            }

            executionLoopPanel

            VStack(alignment: .leading, spacing: 10) {
                missionSignal(title: "Last", value: summary.lastEventTitle, symbol: "waveform.path.ecg", tint: AgentPalette.cyan)
                missionSignal(title: "Next", value: summary.nextStep, symbol: "arrow.right.circle.fill", tint: AgentPalette.green, accessibilityIdentifier: "projectNextStepValue")
                missionSignal(title: "Proof", value: latestProofText, symbol: "checkmark.seal.fill", tint: AgentPalette.indigo)
                missionSignal(
                    title: "Blocker",
                    value: summary.blocker.isEmpty ? "No blocker recorded" : summary.blocker,
                    symbol: summary.blocker.isEmpty ? "checkmark.seal.fill" : "exclamationmark.triangle.fill",
                    tint: summary.blocker.isEmpty ? AgentPalette.lilac : AgentPalette.rose
                )
            }
            .padding(.top, 2)

        }
        .padding(16)
        .background(
            LinearGradient(
                colors: [
                    AgentPalette.surface,
                    statusTint.opacity(0.13),
                    AgentPalette.lilac.opacity(0.07),
                    AgentPalette.surfaceAlt.opacity(0.72)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 24, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(statusTint.opacity(0.28), lineWidth: 0.7)
        )
        .shadow(color: AgentPalette.shadow.opacity(0.10), radius: 14, x: 0, y: 8)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("projectBriefing")
    }

    private struct ProjectMetricCard: Identifiable {
        let id: String
        let value: String
        let label: String
        let detail: String
        let symbol: String
        let tint: Color
    }

    private var projectMetricCards: [ProjectMetricCard] {
        [
            ProjectMetricCard(
                id: "chats",
                value: "\(summary.conversationCount)",
                label: "Chats",
                detail: latestChatDetail,
                symbol: "bubble.left.and.bubble.right.fill",
                tint: AgentPalette.cyan
            ),
            ProjectMetricCard(
                id: "runs",
                value: "\(summary.toolRunCount)",
                label: "Runs",
                detail: latestRunDetail,
                symbol: "wrench.and.screwdriver.fill",
                tint: AgentPalette.lilac
            ),
            ProjectMetricCard(
                id: "artifacts",
                value: "\(summary.artifactCount)",
                label: "Artifacts",
                detail: latestArtifactDetail,
                symbol: "shippingbox.fill",
                tint: AgentPalette.green
            ),
            ProjectMetricCard(
                id: "events",
                value: "\(summary.eventCount)",
                label: "Events",
                detail: summary.failureCount == 0 ? summary.lastEventTitle : "\(summary.failureCount) to review",
                symbol: "timeline.selection",
                tint: summary.failureCount == 0 ? AgentPalette.indigo : AgentPalette.rose
            )
        ]
    }

    private var projectSignals: some View {
        VStack(spacing: 0) {
            Color.clear
                .frame(width: 1, height: 1)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Project metrics")
                .accessibilityIdentifier("projectMetricGrid")

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                ForEach(projectMetricCards) { metric in
                    signalCard(metric)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("projectMetricGrid")
    }

    private var projectCommandCenter: some View {
        sectionShell(
            title: "Command Center",
            subtitle: commandReadout,
            symbol: "command",
            tint: commandTint(for: selectedCommandIntent)
        ) {
            VStack(alignment: .leading, spacing: 12) {
                commandIntentGrid
                commandContextField
                commandActionBar
                commandSurfaceLinks
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("projectCommandCenter")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("projectCommandCenter")
    }

    private var commandIntentGrid: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(ProjectCommandIntent.allCases) { intent in
                    Button {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        withAnimation((reduceMotion || !AgentPerformance.allowsDecorativeMotion) ? nil : .smooth(duration: 0.24)) {
                            selectedCommandIntent = intent
                        }
                    } label: {
                        commandIntentCard(intent)
                    }
                    .buttonStyle(.plain)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("\(intent.displayName). \(commandDetail(for: intent))")
                    .accessibilityAddTraits(selectedCommandIntent == intent ? .isSelected : [])
                    .accessibilityIdentifier("projectCommandIntent-\(intent.rawValue)")
                }
            }
            .padding(.horizontal, 1)
        }
    }

    private func commandIntentCard(_ intent: ProjectCommandIntent) -> some View {
        let selected = selectedCommandIntent == intent
        let recommended = recommendedCommandIntent == intent
        let tint = commandTint(for: intent)

        return VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .center, spacing: 7) {
                Image(systemName: commandSymbol(for: intent))
                    .font(.system(size: 12, weight: .black))
                    .foregroundStyle(tint)
                    .frame(width: 26, height: 26)
                    .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

                Text(intent.compactName)
                    .font(.system(size: 11.5, weight: .black, design: AgentPalette.interfaceFontDesign))
                    .foregroundStyle(AgentPalette.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.76)

                if recommended {
                    Text("SMART")
                        .font(.system(size: 7.5, weight: .black, design: AgentPalette.interfaceFontDesign))
                        .foregroundStyle(tint)
                        .padding(.horizontal, 5)
                        .frame(height: 16)
                        .background(tint.opacity(0.11), in: Capsule(style: .continuous))
                        .accessibilityHidden(true)
                }
            }

            Text(commandDetail(for: intent))
                .font(.system(size: 9.5, weight: .semibold, design: AgentPalette.interfaceFontDesign))
                .foregroundStyle(selected ? AgentPalette.secondaryText : AgentPalette.tertiaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.82)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .frame(width: 148, height: 66, alignment: .leading)
        .agentControlSurface(radius: 15, tint: tint.opacity(selected ? 0.16 : 0.08), selected: selected)
    }

    private var commandContextField: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
                Image(systemName: "text.alignleft")
                    .font(.system(size: 10, weight: .black))
                    .foregroundStyle(commandTint(for: selectedCommandIntent))
                Text("Context")
                    .font(.system(size: 10, weight: .black, design: AgentPalette.interfaceFontDesign))
                    .foregroundStyle(AgentPalette.secondaryText)
                Spacer(minLength: 0)
                if !trimmedCommandContext.isEmpty {
                    Button {
                        commandContext = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 13, weight: .black))
                            .foregroundStyle(AgentPalette.tertiaryText)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear project command context")
                    .accessibilityIdentifier("projectCommandContextClear")
                }
            }

            TextField("Goal, constraint, file, or artifact", text: $commandContext, axis: .vertical)
                .font(.system(size: 12, weight: .semibold, design: AgentPalette.interfaceFontDesign))
                .foregroundStyle(AgentPalette.ink)
                .textInputAutocapitalization(.sentences)
                .lineLimit(2...4)
                .padding(10)
                .frame(minHeight: 48, alignment: .topLeading)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(AgentPalette.row.opacity(0.72))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(commandTint(for: selectedCommandIntent).opacity(0.18), lineWidth: 0.55)
                )
                .accessibilityIdentifier("projectCommandContextField")
        }
    }

    private var commandActionBar: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: commandSymbol(for: selectedCommandIntent))
                    .font(.system(size: 11, weight: .black))
                    .foregroundStyle(commandTint(for: selectedCommandIntent))
                    .frame(width: 28, height: 28)
                    .background(commandTint(for: selectedCommandIntent).opacity(0.11), in: RoundedRectangle(cornerRadius: 9, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    Text(selectedCommandIntent.displayName)
                        .font(.system(size: 12, weight: .black, design: AgentPalette.interfaceFontDesign))
                        .foregroundStyle(AgentPalette.ink)
                        .lineLimit(1)
                    Text(selectedCommandIntent.instructionFocus)
                        .font(.system(size: 10, weight: .semibold, design: AgentPalette.interfaceFontDesign))
                        .foregroundStyle(AgentPalette.secondaryText)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)
            }

            HStack(spacing: 9) {
                Button {
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    draftProjectCommand(project, selectedCommandIntent, trimmedCommandContext)
                } label: {
                    Label("Draft", systemImage: "square.and.pencil")
                        .font(.system(size: 12, weight: .black, design: AgentPalette.interfaceFontDesign))
                        .frame(maxWidth: .infinity, minHeight: AgentDesign.minimumTouchTarget)
                }
                .buttonStyle(.plain)
                .foregroundStyle(AgentPalette.ink)
                .agentControlSurface(radius: 14, tint: AgentPalette.cyan.opacity(0.10), selected: false)
                .accessibilityIdentifier("projectCommandDraftButton")

                Button {
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    runProjectCommand(project, selectedCommandIntent, trimmedCommandContext)
                } label: {
                    Label(projectRunButtonTitle, systemImage: projectRunButtonSymbol)
                        .font(.system(size: 12, weight: .black, design: AgentPalette.interfaceFontDesign))
                        .frame(maxWidth: .infinity, minHeight: AgentDesign.minimumTouchTarget)
                }
                .buttonStyle(ProjectRunButtonStyle(tint: projectRunButtonTint, isDisabled: commandRunBlocked))
                .disabled(commandRunBlocked)
                .accessibilityHint(commandRunBlocked ? "Finish the current run before starting another project command." : selectedCommandIntent.instructionFocus)
                .accessibilityIdentifier("projectCommandRunButton")
            }
        }
        .padding(10)
        .background(AgentPalette.row.opacity(0.62), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(commandTint(for: selectedCommandIntent).opacity(0.14), lineWidth: 0.55)
        )
    }

    private var commandSurfaceLinks: some View {
        HStack(spacing: 8) {
            commandSurfaceLink(title: "Chat", symbol: "sparkles", tab: .chat, tint: AgentPalette.cyan)
            commandSurfaceLink(title: "Files", symbol: "folder.fill", tab: .files, tint: AgentPalette.storageAccent)
            commandSurfaceLink(title: "Runs", symbol: "waveform.path.ecg", tab: .runs, tint: AgentPalette.lilac)
        }
    }

    private func commandSurfaceLink(title: String, symbol: String, tab: AppTab, tint: Color) -> some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            openTab(tab)
        } label: {
            Label(title, systemImage: symbol)
                .font(.system(size: 10.5, weight: .black, design: AgentPalette.interfaceFontDesign))
                .foregroundStyle(AgentPalette.secondaryText)
                .frame(maxWidth: .infinity, minHeight: 36)
        }
        .buttonStyle(.plain)
        .agentControlSurface(radius: 12, tint: tint.opacity(0.08), selected: false)
        .accessibilityIdentifier("projectCommandOpen\(title)")
    }

    @ViewBuilder
    private var missionOSPanel: some View {
        let _ = AgentPerformance.bodyEvaluation("Project Mission OS Body")
        let contract = summary.missionContract
        let tint = missionOSTint(for: contract)
        sectionShell(
            title: "Mission OS",
            subtitle: "\(contract.readinessScore)% · \(contract.phase.displayName)",
            symbol: "point.3.connected.trianglepath.dotted",
            tint: tint,
            usesGlass: true
        ) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: contract.phase.symbolName)
                        .font(.system(size: 17, weight: .black))
                        .foregroundStyle(tint)
                        .frame(width: 42, height: 42)
                        .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 13, style: .continuous)
                                .strokeBorder(tint.opacity(0.22), lineWidth: 0.6)
                        )

                    VStack(alignment: .leading, spacing: 5) {
                        Text(contract.headline)
                            .font(.system(size: 15, weight: .black, design: AgentPalette.interfaceFontDesign))
                            .foregroundStyle(AgentPalette.ink)
                            .lineLimit(2)
                            .minimumScaleFactor(0.82)
                            .accessibilityIdentifier("missionOSHeadline")

                        Text(missionOSDirectiveText(for: contract))
                            .font(.system(size: 11, weight: .semibold, design: AgentPalette.interfaceFontDesign))
                            .foregroundStyle(AgentPalette.secondaryText)
                            .lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer(minLength: 0)

                    VStack(alignment: .trailing, spacing: 2) {
                        Text("\(contract.readinessScore)")
                            .font(.system(size: 25, weight: .black, design: AgentPalette.interfaceFontDesign))
                            .foregroundStyle(tint)
                            .lineLimit(1)
                            .minimumScaleFactor(0.72)
                            .accessibilityIdentifier("missionOSReadinessScore")
                        Text("ready")
                            .font(.system(size: 9, weight: .black, design: AgentPalette.interfaceFontDesign))
                            .foregroundStyle(AgentPalette.tertiaryText)
                    }
                    .frame(width: 52, alignment: .trailing)
                }

                missionOSReadinessBar(score: contract.readinessScore, tint: tint)

                HStack(spacing: 8) {
                    missionOSStateBadge(
                        label: "Phase",
                        value: contract.phase.displayName,
                        symbol: contract.phase.symbolName,
                        tint: tint
                    )
                    missionOSStateBadge(
                        label: "Run",
                        value: missionOSRunStatusLabel(for: contract),
                        symbol: commandSymbol(for: contract.recommendedIntent),
                        tint: commandTint(for: contract.recommendedIntent)
                    )
                    missionOSStateBadge(
                        label: "Status",
                        value: missionOSDecisionStatusLabel(for: contract),
                        symbol: "arrow.triangle.branch",
                        tint: missionOSDecisionTint(for: contract)
                    )
                }

                missionSignal(
                    title: "Proof requirement",
                    value: contract.proofRequirement,
                    symbol: "checkmark.seal.fill",
                    tint: missionOSGateTint(.satisfied)
                )
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("missionOSPanel")
    }

    private var missionOSGateSection: some View {
        let contract = summary.missionContract
        let tint = missionOSTint(for: contract)

        return sectionShell(
            title: "Mission Gates",
            subtitle: "\(contract.gates.filter { $0.state == .satisfied }.count)/\(contract.gates.count) clear",
            symbol: "checklist.checked",
            tint: tint
        ) {
            VStack(spacing: 0) {
                ForEach(Array(contract.gates.enumerated()), id: \.element.id) { index, gate in
                    missionOSGateRow(gate)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("\(gate.title). \(gate.state.displayName). \(gate.detail)")
                        .accessibilityIdentifier("missionOSGate-\(gate.id)")

                    if index < contract.gates.count - 1 {
                        Divider()
                            .overlay(AgentPalette.border.opacity(0.34))
                            .padding(.leading, 42)
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(AgentPalette.row.opacity(0.66), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(tint.opacity(0.14), lineWidth: 0.55)
            )
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("missionOSGateSection")
    }

    private func missionOSReadinessBar(score: Int, tint: Color) -> some View {
        ProgressView(value: Double(max(0, min(score, 100))), total: 100)
            .progressViewStyle(.linear)
            .tint(tint)
            .scaleEffect(x: 1, y: 0.72, anchor: .center)
            .clipShape(Capsule())
            .frame(maxWidth: .infinity)
            .frame(height: 8)
            .accessibilityHidden(true)
    }

    private func missionOSDirectiveText(for contract: MissionOSContract) -> String {
        let directive = contract.operatorDirective.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !directive.isEmpty else { return contract.proofRequirement }

        if !contract.blockingGates.isEmpty {
            let recoveryText = directive
                .replacingOccurrences(of: "\(ProjectCommandIntent.fixBlocker.displayName): ", with: "")
                .replacingOccurrences(of: "\(ProjectCommandIntent.fixBlocker.displayName):", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return recoveryText.isEmpty ? "Run will recover from the active blocker." : "Run will recover: \(recoveryText)"
        }

        return directive
    }

    private func missionOSRunStatusLabel(for contract: MissionOSContract) -> String {
        if !contract.blockingGates.isEmpty { return "Recovery" }

        switch contract.recommendedIntent {
        case .continueMission:
            return "Continue"
        case .planNext:
            return "Plan"
        case .verifyWork:
            return "Verify"
        case .improveArtifact:
            return "Improve"
        case .fixBlocker:
            return "Recovery"
        case .reviewEvidence:
            return "Review"
        }
    }

    private func missionOSDecisionStatusLabel(for contract: MissionOSContract) -> String {
        if !contract.blockingGates.isEmpty { return "Blocked" }

        switch contract.decisionLabel {
        case "Review approval":
            return "Waiting"
        case "Ready to review":
            return "Proof ready"
        case "Needs checkpoint":
            return "Checkpoint"
        case "Needs verification":
            return "Verify next"
        case "Needs proof":
            return "Proof next"
        case "Continue mission":
            return "Ready"
        default:
            return contract.decisionLabel
        }
    }

    private func missionOSGateRow(_ gate: MissionOSGate) -> some View {
        let tint = missionOSGateTint(gate.state)
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: gate.state.symbolName)
                .font(.system(size: 12, weight: .black))
                .foregroundStyle(tint)
                .frame(width: 28, height: 28)
                .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 9, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Text(gate.title)
                        .font(.system(size: 11.5, weight: .black, design: AgentPalette.interfaceFontDesign))
                        .foregroundStyle(AgentPalette.ink)
                        .lineLimit(1)
                        .minimumScaleFactor(0.82)
                    Text(gate.state.displayName)
                        .font(.system(size: 8.5, weight: .black, design: AgentPalette.interfaceFontDesign))
                        .foregroundStyle(tint)
                        .padding(.horizontal, 6)
                        .frame(height: 18)
                        .background(tint.opacity(0.10), in: Capsule(style: .continuous))
                    Spacer(minLength: 0)
                }

                Text(gate.detail)
                    .font(.system(size: 10, weight: .semibold, design: AgentPalette.interfaceFontDesign))
                    .foregroundStyle(AgentPalette.secondaryText)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 9)
    }

    private var statusBadge: some View {
        miniBadge(title: summary.statusText, symbol: statusSymbol, tint: statusTint)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(summary.statusText)
            .accessibilityIdentifier("projectStatusPill")
    }

    private var missionCopy: String {
        summary.missionText
    }

    private var lastActivityText: String {
        if Calendar.current.isDateInToday(project.lastActivityAt) {
            return DateFormatter.localizedString(from: project.lastActivityAt, dateStyle: .none, timeStyle: .short)
        }
        return DateFormatter.localizedString(from: project.lastActivityAt, dateStyle: .short, timeStyle: .none)
    }

    private var latestChatDetail: String {
        guard let latest = projectConversations.first else {
            return "No chats yet"
        }
        return latest.title
    }

    private var latestRunDetail: String {
        if summary.pendingApprovalCount > 0 {
            return "\(summary.pendingApprovalCount) pending"
        }
        guard let latest = projectRuns.first else {
            return "No runs yet"
        }
        return "\(runStatusText(latest.status)) · \(latest.name)"
    }

    private var latestArtifactDetail: String {
        if let artifact = projectArtifacts.first {
            return artifact.title
        }
        return summary.fileChangeCount == 0 ? "No artifacts yet" : "\(summary.fileChangeCount) file changes"
    }

    private var currentWorkText: String {
        if runtimeStatus.isVisible {
            return runtimeStatus.title
        }
        return summary.workflowSpine.currentTitle
    }

    private var changedArtifactText: String {
        let spine = summary.workflowSpine
        if spine.changedTitle == spine.changedDetail { return spine.changedTitle }
        return "\(spine.changedTitle): \(spine.changedDetail)"
    }

    private var blockerSnapshotText: String {
        summary.workflowSpine.blockerDetail
    }

    private var recommendedCommandIntent: ProjectCommandIntent {
        summary.missionContract.recommendedIntent
    }

    private var trimmedCommandContext: String {
        commandContext.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var commandRunBlocked: Bool {
        runtimeStatus.blocksCommand
    }

    private var projectRunButtonTitle: String {
        switch runtimeStatus.tone {
        case .approval:
            return "Waiting"
        case .working:
            return "Running"
        default:
            return "Run"
        }
    }

    private var projectRunButtonSymbol: String {
        switch runtimeStatus.tone {
        case .approval:
            return "checkmark.shield.fill"
        case .working:
            return "waveform"
        default:
            return "play.fill"
        }
    }

    private var projectRunButtonTint: Color {
        runtimeStatus.isVisible ? runtimeStatus.tint : commandTint(for: recommendedCommandIntent)
    }

    private var commandReadout: String {
        if runtimeStatus.blocksCommand {
            return runtimeStatus.title
        }
        if selectedCommandIntent == recommendedCommandIntent {
            return "Recommended for this project"
        }
        return commandDetail(for: selectedCommandIntent)
    }

    private var latestProofText: String {
        let spine = summary.workflowSpine
        if spine.proofTitle == "No proof captured yet" || spine.proofTitle == spine.proofDetail {
            return spine.proofDetail
        }
        return "\(spine.proofTitle): \(spine.proofDetail)"
    }

    private var nextStepReason: String {
        let contract = summary.missionContract
        if let gate = contract.blockingGates.first {
            return "Clears \(gate.title.lowercased()): \(gate.detail)"
        }
        if summary.pendingApprovalCount > 0 {
            return "A saved run is waiting for review before the next safe action."
        }
        if summary.review.hasStaleProof {
            return summary.workflowSpine.proofDetail
        }
        let directive = contract.operatorDirective.trimmingCharacters(in: .whitespacesAndNewlines)
        if !directive.isEmpty {
            return directive
        }
        return commandDetail(for: recommendedCommandIntent)
    }

    private var expectedProofText: String {
        if summary.review.hasStaleProof {
            return "Refresh proof so it matches the latest project iteration."
        }
        let requirement = summary.missionContract.proofRequirement
        if requirement.contains("Create an openable artifact") {
            return "Create proof: artifact, file change, run, terminal log, or screenshot."
        }
        if requirement.contains("Proof exists, but it still needs") {
            return "Proof exists; add a check, build, or test receipt next."
        }
        if requirement.contains("Close the run with Agent Plan") {
            return "Close with Agent Plan and Agent Proof checkpoints."
        }
        return requirement
    }

    private var approvalExpectationText: String {
        if runtimeStatus.tone == .approval {
            return "Approval is waiting now."
        }
        if commandRunBlocked {
            return "Finish the current run before starting another."
        }
        if summary.pendingApprovalCount > 0 {
            return "\(summary.pendingApprovalCount) approval\(summary.pendingApprovalCount == 1 ? "" : "s") already waiting."
        }
        switch recommendedCommandIntent {
        case .reviewEvidence:
            return "No approval expected for read-only evidence review."
        case .verifyWork:
            return "May pause before simulator, shell, or file checks."
        case .fixBlocker:
            return "May pause before mutating files or running recovery tools."
        case .continueMission, .planNext, .improveArtifact:
            return "May pause before edits, commands, or tool use."
        }
    }

    private var approvalExpectationSymbol: String {
        runtimeStatus.tone == .approval || summary.pendingApprovalCount > 0 ? "checkmark.shield.fill" : "lock.open.fill"
    }

    private var approvalExpectationTint: Color {
        runtimeStatus.tone == .approval || summary.pendingApprovalCount > 0 ? AgentPalette.cyan : AgentPalette.lilac
    }

    private var autoContinueStateLine: String {
        if autoContinueState.isCountingDown {
            return "\(autoContinueState.detail) Starts in \(autoContinueState.remainingSeconds)s."
        }
        if !autoContinueState.isEnabled {
            return "Off for this project."
        }
        if autoContinueState.isPaused {
            return "Paused. Resume when ready."
        }
        if autoContinueState.state == .blocked {
            return autoContinueState.detail
        }
        return autoContinueState.detail
    }

    private var autoContinueSymbol: String {
        if autoContinueState.isCountingDown { return "timer" }
        if autoContinueState.isPaused { return "pause.circle.fill" }
        if autoContinueState.state == .blocked { return "hand.raised.fill" }
        return autoContinueState.isEnabled ? "arrow.triangle.2.circlepath.circle.fill" : "arrow.triangle.2.circlepath"
    }

    private var autoContinueTint: Color {
        if autoContinueState.isCountingDown { return AgentPalette.green }
        if autoContinueState.isPaused { return AgentPalette.lilac }
        if autoContinueState.state == .blocked { return AgentPalette.rose }
        return autoContinueState.isEnabled ? AgentPalette.green : AgentPalette.tertiaryText
    }

    private var artifactSectionSubtitle: String {
        if projectArtifacts.isEmpty { return "No project artifacts yet" }
        return "\(projectArtifacts.count) project artifact\(projectArtifacts.count == 1 ? "" : "s")"
    }

    private var fileChangesSectionSubtitle: String {
        if projectFileChanges.isEmpty { return "No file changes yet" }
        return "\(projectFileChanges.count) recorded change\(projectFileChanges.count == 1 ? "" : "s")"
    }

    private var timelineSectionSubtitle: String {
        if projectEvents.isEmpty { return "No timeline events yet" }
        return "\(projectEvents.count) recorded event\(projectEvents.count == 1 ? "" : "s")"
    }

    private var trustTint: Color {
        if summary.failureCount > 0 { return AgentPalette.rose }
        if summary.pendingApprovalCount > 0 { return AgentPalette.lilac }
        return AgentPalette.green
    }

    private var proofFreshnessTint: Color {
        if summary.review.hasStaleProof { return AgentPalette.rose }
        if summary.review.hasMissingEvidence { return AgentPalette.lilac }
        return AgentPalette.green
    }

    private func reviewTint(for recommendation: ProjectReviewRecommendation) -> Color {
        switch recommendation {
        case .continueMission:
            return AgentPalette.green
        case .verifyWork:
            return AgentPalette.lilac
        case .askUser:
            return AgentPalette.cyan
        case .fixBlocker:
            return AgentPalette.rose
        case .finalReview:
            return AgentPalette.green
        }
    }

    private func reviewFindingTint(_ severity: ProjectEventSeverity) -> Color {
        switch severity {
        case .failure:
            return AgentPalette.rose
        case .warning:
            return AgentPalette.lilac
        case .running:
            return AgentPalette.cyan
        case .success:
            return AgentPalette.green
        case .info:
            return AgentPalette.indigo
        }
    }

    private func phaseIndex(_ phase: MissionOSPhase) -> Int {
        MissionOSPhase.allCases.firstIndex(of: phase) ?? 0
    }

    private func phaseTrackTint(_ phase: MissionOSPhase, contract: MissionOSContract) -> Color {
        if phase == contract.phase {
            return missionOSTint(for: contract)
        }
        if phaseIndex(phase) < phaseIndex(contract.phase) {
            return AgentPalette.green
        }
        return AgentPalette.tertiaryText
    }

    private func missionOSTint(for contract: MissionOSContract) -> Color {
        if !contract.blockingGates.isEmpty { return AgentPalette.rose }
        if contract.readinessScore >= 85 { return AgentPalette.green }
        if contract.readinessScore >= 58 { return AgentPalette.lilac }
        return AgentPalette.cyan
    }

    private func missionOSDecisionTint(for contract: MissionOSContract) -> Color {
        if !contract.blockingGates.isEmpty { return AgentPalette.rose }
        if contract.readinessScore >= 85 { return AgentPalette.green }
        if contract.phase == .verify || contract.phase == .proof { return AgentPalette.lilac }
        return AgentPalette.cyan
    }

    private func missionOSGateTint(_ state: MissionOSGateState) -> Color {
        switch state {
        case .satisfied: AgentPalette.green
        case .waiting: AgentPalette.lilac
        case .blocked: AgentPalette.rose
        }
    }

    private func liveProgressTint(for state: WorkspaceProgressStep.State) -> Color {
        switch state {
        case .pending: AgentPalette.tertiaryText
        case .current: AgentPalette.cyan
        case .done: AgentPalette.green
        case .blocked: AgentPalette.rose
        }
    }

    private func liveProgressSymbol(for step: WorkspaceProgressStep) -> String {
        switch step.state {
        case .pending:
            return "circle"
        case .current:
            return step.symbolName
        case .done:
            return "checkmark.circle.fill"
        case .blocked:
            return "exclamationmark.triangle.fill"
        }
    }

    private func liveProgressStateLabel(_ state: WorkspaceProgressStep.State) -> String {
        switch state {
        case .pending: "Next"
        case .current: "Now"
        case .done: "Done"
        case .blocked: "Blocked"
        }
    }

    private func commandSymbol(for intent: ProjectCommandIntent) -> String {
        switch intent {
        case .continueMission: "arrow.triangle.2.circlepath"
        case .planNext: "list.bullet.clipboard.fill"
        case .verifyWork: "checkmark.shield.fill"
        case .improveArtifact: "wand.and.sparkles"
        case .fixBlocker: "wrench.and.screwdriver.fill"
        case .reviewEvidence: "doc.text.magnifyingglass"
        }
    }

    private func commandTint(for intent: ProjectCommandIntent) -> Color {
        switch intent {
        case .continueMission: AgentPalette.green
        case .planNext: AgentPalette.cyan
        case .verifyWork: AgentPalette.lilac
        case .improveArtifact: AgentPalette.green
        case .fixBlocker: AgentPalette.rose
        case .reviewEvidence: AgentPalette.indigo
        }
    }

    private func commandDetail(for intent: ProjectCommandIntent) -> String {
        let spine = summary.workflowSpine
        switch intent {
        case .continueMission:
            return spine.nextActionDetail.isEmpty ? "Choose the best next action" : spine.nextActionDetail
        case .planNext:
            return "Plan from \(spine.changedDetail)"
        case .verifyWork:
            return summary.review.hasStaleProof ? "Refresh proof for current work" : "Verify \(spine.changedDetail)"
        case .improveArtifact:
            return spine.latestArtifactPath.map { "Improve \(URL(fileURLWithPath: $0).lastPathComponent)" } ?? "Improve \(spine.changedDetail)"
        case .fixBlocker:
            return spine.blockerDetail
        case .reviewEvidence:
            return spine.proofTitle == "No proof captured yet" ? "Read timeline and proof" : "Review \(spine.proofTitle)"
        }
    }

    private func miniBadge(title: String, symbol: String, tint: Color) -> some View {
        Label {
            Text(title)
                .font(.system(size: 10, weight: .black, design: AgentPalette.interfaceFontDesign))
                .lineLimit(1)
                .minimumScaleFactor(0.78)
        } icon: {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .black))
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 9)
        .frame(height: 28)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(tint.opacity(0.12))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(tint.opacity(0.22), lineWidth: 0.55)
        )
    }

    private func missionOSStateBadge(label: String, value: String, symbol: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label.uppercased())
                .font(.system(size: 7.5, weight: .black, design: AgentPalette.interfaceFontDesign))
                .foregroundStyle(AgentPalette.tertiaryText)
                .lineLimit(1)

            Label {
                Text(value)
                    .font(.system(size: 10, weight: .black, design: AgentPalette.interfaceFontDesign))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            } icon: {
                Image(systemName: symbol)
                    .font(.system(size: 9, weight: .black))
            }
            .foregroundStyle(tint)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, minHeight: 46, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(tint.opacity(0.09))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(tint.opacity(0.18), lineWidth: 0.55)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label): \(value)")
    }

    private func spineDatum(title: String, value: String, symbol: String, tint: Color) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .black))
                .foregroundStyle(tint)
                .frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 9, weight: .black, design: AgentPalette.interfaceFontDesign))
                    .foregroundStyle(AgentPalette.tertiaryText)
                Text(value.isEmpty ? "None" : value)
                    .font(.system(size: 11, weight: .bold, design: AgentPalette.interfaceFontDesign))
                    .foregroundStyle(AgentPalette.ink)
                    .lineLimit(2)
                    .minimumScaleFactor(0.78)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .fill(AgentPalette.row.opacity(0.74))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .strokeBorder(tint.opacity(0.18), lineWidth: 0.55)
        )
    }

    private func missionSignal(title: String, value: String, symbol: String, tint: Color, accessibilityIdentifier: String? = nil) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .black))
                .foregroundStyle(tint)
                .frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 9, weight: .black, design: AgentPalette.interfaceFontDesign))
                    .foregroundStyle(AgentPalette.tertiaryText)
                Text(value.isEmpty ? "None" : value)
                    .font(.system(size: 12, weight: .bold, design: AgentPalette.interfaceFontDesign))
                    .foregroundStyle(AgentPalette.ink)
                    .lineLimit(3)
                    .minimumScaleFactor(0.8)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier(accessibilityIdentifier ?? "")
            }
            Spacer(minLength: 0)
        }
    }

    private var executionLoopPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .font(.system(size: 11, weight: .black))
                    .foregroundStyle(AgentPalette.green)
                Text("Execution Loop")
                    .font(.system(size: 11, weight: .black, design: AgentPalette.interfaceFontDesign))
                    .foregroundStyle(AgentPalette.ink)
                Spacer(minLength: 0)
                Text(summary.statusText)
                    .font(.system(size: 9, weight: .black, design: AgentPalette.interfaceFontDesign))
                    .foregroundStyle(statusTint)
                    .padding(.horizontal, 8)
                    .frame(height: 22)
                    .background(statusTint.opacity(0.10), in: Capsule(style: .continuous))
            }

            VStack(spacing: 0) {
                executionLoopRow(
                    title: "Chat",
                    value: latestChatDetail,
                    detail: projectConversations.first.map { "\($0.messageCount) message\($0.messageCount == 1 ? "" : "s")" } ?? "Ready to start",
                    symbol: "bubble.left.and.bubble.right.fill",
                    tint: AgentPalette.cyan
                )

                Divider().overlay(AgentPalette.border.opacity(0.35)).padding(.leading, 38)

                executionLoopRow(
                    title: "Run",
                    value: projectRuns.first.map { $0.name } ?? "No runs yet",
                    detail: projectRuns.first.map { runStatusText($0.status) } ?? "Tools will appear here",
                    symbol: "wrench.and.screwdriver.fill",
                    tint: AgentPalette.lilac
                )

                Divider().overlay(AgentPalette.border.opacity(0.35)).padding(.leading, 38)

                executionLoopRow(
                    title: "Proof",
                    value: summary.proofItems.first?.title ?? "No proof yet",
                    detail: summary.proofItems.first?.detail ?? "Artifacts, files, runs, and events build the ledger",
                    symbol: "checkmark.seal.fill",
                    tint: AgentPalette.green
                )
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(AgentPalette.row.opacity(0.68), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(AgentPalette.green.opacity(0.14), lineWidth: 0.55)
            )
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("projectExecutionLoop")
    }

    private func executionLoopRow(title: String, value: String, detail: String, symbol: String, tint: Color) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .black))
                .foregroundStyle(tint)
                .frame(width: 28, height: 28)
                .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 9, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 9, weight: .black, design: AgentPalette.interfaceFontDesign))
                    .foregroundStyle(AgentPalette.tertiaryText)
                Text(value)
                    .font(.system(size: 11.5, weight: .black, design: AgentPalette.interfaceFontDesign))
                    .foregroundStyle(AgentPalette.ink)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(detail)
                    .font(.system(size: 9.5, weight: .semibold, design: AgentPalette.interfaceFontDesign))
                    .foregroundStyle(AgentPalette.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 8)
    }

    private func signalCard(_ metric: ProjectMetricCard) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: metric.symbol)
                    .font(.system(size: 13, weight: .black))
                    .foregroundStyle(metric.tint)
                    .frame(width: 28, height: 28)
                    .background(
                        Circle()
                            .fill(metric.tint.opacity(0.12))
                    )
                Spacer(minLength: 0)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(metric.value)
                    .font(.system(size: 25, weight: .black, design: AgentPalette.interfaceFontDesign))
                    .foregroundStyle(AgentPalette.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                Text(metric.label)
                    .font(.system(size: 10, weight: .black, design: AgentPalette.interfaceFontDesign))
                    .foregroundStyle(AgentPalette.secondaryText)
                    .lineLimit(1)
                Text(metric.detail)
                    .font(.system(size: 10, weight: .semibold, design: AgentPalette.interfaceFontDesign))
                    .foregroundStyle(AgentPalette.tertiaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(13)
        .agentSurface(radius: 18, tint: metric.tint.opacity(0.08))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(metric.label): \(metric.value). \(metric.detail)")
        .accessibilityIdentifier("projectMetric-\(metric.id)")
    }

    @ViewBuilder
    private var artifactsSection: some View {
        sectionShell(
            title: "Project Artifacts",
            subtitle: artifactSectionSubtitle,
            symbol: "shippingbox.fill",
            tint: AgentPalette.green
        ) {
            let visibleArtifacts = Array(projectArtifacts.prefix(5))
            if visibleArtifacts.isEmpty {
                emptyState(title: "No artifacts yet", detail: "Generated files and previews will land here.", symbol: "shippingbox", tint: AgentPalette.green)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    artifactFeatureCard(visibleArtifacts[0])

                    if visibleArtifacts.count > 1 {
                        VStack(spacing: 0) {
                            ForEach(Array(visibleArtifacts.dropFirst().enumerated()), id: \.element.id) { index, artifact in
                                Button {
                                    openProjectArtifact(artifact)
                                } label: {
                                    artifactRow(artifact)
                                }
                                .buttonStyle(.plain)
                                .accessibilityIdentifier("projectArtifact-\(artifact.path)")

                                if index < visibleArtifacts.dropFirst().count - 1 {
                                    Divider()
                                        .overlay(AgentPalette.border.opacity(0.42))
                                        .padding(.leading, 44)
                                }
                            }
                        }
                    }

                    if projectArtifacts.count > visibleArtifacts.count {
                        Button {
                            openTab(.files)
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "folder.fill")
                                    .font(.system(size: 10, weight: .black))
                                Text("\(projectArtifacts.count - visibleArtifacts.count) more in Files")
                                    .font(.system(size: 10.5, weight: .black, design: AgentPalette.interfaceFontDesign))
                                Spacer(minLength: 0)
                                Image(systemName: "arrow.right")
                                    .font(.system(size: 10, weight: .black))
                            }
                            .foregroundStyle(AgentPalette.green)
                            .padding(.horizontal, 10)
                            .frame(minHeight: 36)
                            .background(AgentPalette.green.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("projectArtifactOverflowButton")
                    }
                }
            }
        }
    }

    private var timelineSection: some View {
        sectionShell(
            title: "Project Timeline",
            subtitle: summary.timelineItems.isEmpty ? "No timeline events yet" : "\(summary.timelineItems.count) event\(summary.timelineItems.count == 1 ? "" : "s")",
            symbol: "timeline.selection",
            tint: AgentPalette.indigo
        ) {
            let visibleEvents = Array(summary.timelineItems.prefix(12))
            if visibleEvents.isEmpty {
                emptyState(title: "Waiting", detail: "No project events recorded yet.", symbol: "circle.dashed", tint: AgentPalette.secondaryText)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(visibleEvents.enumerated()), id: \.element.id) { index, item in
                        timelineRow(item)
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel("\(item.title). \(item.detail)")
                            .accessibilityIdentifier("projectTimelineRow-\(index)")

                        if index < visibleEvents.count - 1 {
                            Divider()
                                .overlay(AgentPalette.border.opacity(0.36))
                                .padding(.leading, 42)
                        }
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("projectTimelineSection")
    }

    private var proofLedgerSection: some View {
        sectionShell(
            title: "Proof Ledger",
            subtitle: summary.proofItems.isEmpty ? "No proof captured yet" : "\(summary.proofItems.count) proof item\(summary.proofItems.count == 1 ? "" : "s")",
            symbol: "checkmark.seal.fill",
            tint: AgentPalette.green
        ) {
            let visibleProof = Array(summary.proofItems.prefix(6))
            if visibleProof.isEmpty {
                emptyState(title: "No proof captured yet", detail: "Screenshots, artifacts, completed runs, and file evidence will appear here.", symbol: "checkmark.seal", tint: AgentPalette.green)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(visibleProof.enumerated()), id: \.element.id) { index, item in
                        Button {
                            openProofItem(item)
                        } label: {
                            proofLedgerRow(item)
                        }
                        .buttonStyle(.plain)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("\(item.title). \(item.detail)")
                        .accessibilityIdentifier("projectProofLedgerRow-\(index)")

                        if index < visibleProof.count - 1 {
                            Divider()
                                .overlay(AgentPalette.border.opacity(0.36))
                                .padding(.leading, 44)
                        }
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("projectProofLedgerSection")
    }

    private var fileChangesSection: some View {
        sectionShell(
            title: "Changes",
            subtitle: fileChangesSectionSubtitle,
            symbol: "doc.badge.gearshape.fill",
            tint: AgentPalette.cyan
        ) {
            let visibleChanges = Array(projectFileChanges.prefix(4))
            if visibleChanges.isEmpty {
                emptyState(title: "No file changes yet", detail: "Workspace edits will appear here as project-owned records.", symbol: "doc.badge.plus", tint: AgentPalette.cyan)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(visibleChanges.enumerated()), id: \.element.id) { index, change in
                        fileChangeRow(change)

                        if index < visibleChanges.count - 1 {
                            Divider()
                                .overlay(AgentPalette.border.opacity(0.36))
                                .padding(.leading, 44)
                        }
                    }
                }
            }
        }
    }

    private func openProjectArtifact(_ artifact: ProjectArtifact) {
        let workspaceArtifact = WorkspaceArtifact(path: artifact.path)
        ProjectEventRecorder.noteArtifactPreview(
            workspaceArtifact,
            project: project,
            context: modelContext
        )
        try? modelContext.save()
        if workspaceArtifact.isWebPage || workspaceArtifact.isSwiftGameArtifact {
            openArtifactLandscapeFullScreen(workspaceArtifact)
        } else {
            openTab(.files)
        }
    }

    private func openProofItem(_ item: ProjectProofItem) {
        guard let path = item.sourcePath, !path.isEmpty else {
            selectedProofItem = item
            return
        }
        if let artifact = projectArtifacts.first(where: { $0.path == path }) {
            openProjectArtifact(artifact)
            return
        }
        selectedProofItem = item
    }

    private func proofLedgerRow(_ item: ProjectProofItem) -> some View {
        let tint = proofTint(for: item)
        return HStack(spacing: 11) {
            Image(systemName: item.symbolName)
                .font(.system(size: 13, weight: .black))
                .foregroundStyle(tint)
                .frame(width: 32, height: 32)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(tint.opacity(0.12))
                )

            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.system(size: 12, weight: .black, design: AgentPalette.interfaceFontDesign))
                    .foregroundStyle(AgentPalette.ink)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(item.detail)
                    .font(.system(size: 10, weight: .semibold, design: AgentPalette.interfaceFontDesign))
                    .foregroundStyle(AgentPalette.tertiaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 0)

            Text(eventTimeText(item.createdAt))
                .font(.system(size: 9, weight: .bold, design: AgentPalette.interfaceFontDesign))
                .foregroundStyle(AgentPalette.tertiaryText)
                .lineLimit(1)
        }
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }

    private func proofDetailSheet(_ item: ProjectProofItem) -> some View {
        let tint = proofTint(for: item)
        return VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: item.symbolName)
                    .font(.system(size: 16, weight: .black))
                    .foregroundStyle(tint)
                    .frame(width: 38, height: 38)
                    .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Proof Detail")
                        .font(.system(size: 11, weight: .black, design: AgentPalette.interfaceFontDesign))
                        .foregroundStyle(AgentPalette.tertiaryText)
                    Text(item.title)
                        .font(.system(size: 18, weight: .black, design: AgentPalette.interfaceFontDesign))
                        .foregroundStyle(AgentPalette.ink)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
            }

            Text(item.detail)
                .font(.system(size: 13, weight: .semibold, design: AgentPalette.interfaceFontDesign))
                .foregroundStyle(AgentPalette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)

            if let path = item.sourcePath, !path.isEmpty {
                Text(path)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(AgentPalette.tertiaryText)
                    .lineLimit(4)
                    .truncationMode(.middle)
            }

            Button("Open Files") {
                selectedProofItem = nil
                openTab(.files)
            }
            .buttonStyle(.borderedProminent)
            .tint(tint)
            .accessibilityIdentifier("projectProofDetailOpenFiles")
        }
        .padding(20)
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("projectProofDetailSheet")
    }

    private func artifactFeatureCard(_ artifact: ProjectArtifact) -> some View {
        let type = artifact.type
        let isPlayable = type == .html || type == .swiftGame
        let tint = isPlayable ? AgentPalette.green : AgentPalette.cyan
        let title = artifact.title.isEmpty ? URL(fileURLWithPath: artifact.path).lastPathComponent : artifact.title

        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: type.symbolName)
                    .font(.system(size: 18, weight: .black))
                    .foregroundStyle(tint)
                    .frame(width: 44, height: 44)
                    .background(tint.opacity(0.13), in: RoundedRectangle(cornerRadius: 14, style: .continuous))

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 7) {
                        Text(type == .swiftGame ? "Playable Game" : "Latest Output")
                            .font(.system(size: 9, weight: .black, design: AgentPalette.interfaceFontDesign))
                            .foregroundStyle(tint)
                            .padding(.horizontal, 7)
                            .frame(height: 20)
                            .background(tint.opacity(0.10), in: Capsule(style: .continuous))
                        Text(eventTimeText(artifact.updatedAt))
                            .font(.system(size: 9, weight: .bold, design: AgentPalette.interfaceFontDesign))
                            .foregroundStyle(AgentPalette.tertiaryText)
                    }

                    Text(title)
                        .font(.system(size: 15, weight: .black, design: AgentPalette.interfaceFontDesign))
                        .foregroundStyle(AgentPalette.ink)
                        .lineLimit(2)
                        .minimumScaleFactor(0.8)

                    Text(artifact.path)
                        .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                        .foregroundStyle(AgentPalette.tertiaryText)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }

                Spacer(minLength: 0)
            }

            HStack(spacing: 9) {
                Button {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    openProjectArtifact(artifact)
                } label: {
                    Label(isPlayable ? "Preview" : "Open", systemImage: isPlayable ? "arrow.up.right" : "folder.fill")
                        .font(.system(size: 11, weight: .black, design: AgentPalette.interfaceFontDesign))
                        .frame(maxWidth: .infinity, minHeight: 38)
                }
                .buttonStyle(.plain)
                .foregroundStyle(AgentPalette.ink)
                .agentControlSurface(radius: 13, tint: tint.opacity(0.12), selected: true)
                .accessibilityIdentifier("projectFeaturedArtifactOpen")

                Button {
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    draftProjectCommand(project, .improveArtifact, "Focus on \(artifact.path).")
                } label: {
                    Label("Improve", systemImage: "wand.and.sparkles")
                        .font(.system(size: 11, weight: .black, design: AgentPalette.interfaceFontDesign))
                        .frame(maxWidth: .infinity, minHeight: 38)
                }
                .buttonStyle(.plain)
                .foregroundStyle(AgentPalette.ink)
                .agentControlSurface(radius: 13, tint: AgentPalette.green.opacity(0.10), selected: false)
                .accessibilityIdentifier("projectFeaturedArtifactImprove")
            }
        }
        .padding(12)
        .background(AgentPalette.row.opacity(0.70), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(tint.opacity(0.20), lineWidth: 0.65)
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("projectFeaturedArtifact")
    }

    private func artifactRow(_ artifact: ProjectArtifact) -> some View {
        let type = artifact.type
        let isPlayable = type == .html || type == .swiftGame
        let tint = isPlayable ? AgentPalette.green : AgentPalette.cyan
        return HStack(spacing: 11) {
            Image(systemName: type.symbolName)
                .font(.system(size: 13, weight: .black))
                .foregroundStyle(tint)
                .frame(width: 32, height: 32)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(tint.opacity(0.11))
                )

            VStack(alignment: .leading, spacing: 2) {
                Text(artifact.title.isEmpty ? URL(fileURLWithPath: artifact.path).lastPathComponent : artifact.title)
                    .font(.system(size: 12, weight: .black, design: AgentPalette.interfaceFontDesign))
                    .foregroundStyle(AgentPalette.ink)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(artifact.path)
                    .font(.system(size: 10, weight: .semibold, design: AgentPalette.interfaceFontDesign))
                    .foregroundStyle(AgentPalette.tertiaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 0)

            Image(systemName: isPlayable ? "arrow.up.right" : "folder.fill")
                .font(.system(size: 10, weight: .black))
                .foregroundStyle(AgentPalette.secondaryText)
        }
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }

    private func fileChangeRow(_ change: ProjectFileChange) -> some View {
        HStack(spacing: 11) {
            Image(systemName: "doc.text.fill")
                .font(.system(size: 13, weight: .black))
                .foregroundStyle(AgentPalette.cyan)
                .frame(width: 32, height: 32)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(AgentPalette.cyan.opacity(0.11))
                )

            VStack(alignment: .leading, spacing: 2) {
                Text(change.action)
                    .font(.system(size: 12, weight: .black, design: AgentPalette.interfaceFontDesign))
                    .foregroundStyle(AgentPalette.ink)
                    .lineLimit(1)
                Text(change.path)
                    .font(.system(size: 10, weight: .semibold, design: AgentPalette.interfaceFontDesign))
                    .foregroundStyle(AgentPalette.tertiaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 0)

            Text(eventTimeText(change.createdAt))
                .font(.system(size: 9, weight: .bold, design: AgentPalette.interfaceFontDesign))
                .foregroundStyle(AgentPalette.tertiaryText)
                .lineLimit(1)
        }
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private func sectionShell<Content: View>(
        title: String,
        subtitle: String,
        symbol: String,
        tint: Color,
        usesGlass: Bool = false,
        @ViewBuilder content: () -> Content
    ) -> some View {
        let shell = VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .black))
                    .foregroundStyle(tint)
                Text(title)
                    .font(.system(size: 13, weight: .black, design: AgentPalette.interfaceFontDesign))
                    .foregroundStyle(AgentPalette.ink)
                Spacer(minLength: 0)
                Text(subtitle)
                    .font(.system(size: 10, weight: .bold, design: AgentPalette.interfaceFontDesign))
                    .foregroundStyle(AgentPalette.tertiaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.74)
            }

            content()
        }
        .padding(14)

        if usesGlass {
            shell
                .agentGlass(radius: 22, interactive: false, tint: tint.opacity(0.12))
        } else {
            shell
                .agentSurface(radius: 20, tint: tint.opacity(0.06))
        }
    }

    private func emptyState(title: String, detail: String, symbol: String, tint: Color) -> some View {
        AgentInlineStateView(title: title, detail: detail, symbol: symbol, tint: tint)
    }

    private func timelineRow(_ item: ProjectTimelineItem) -> some View {
        let tint = tint(for: item.severity)

        return HStack(alignment: .top, spacing: 10) {
            VStack(spacing: 4) {
                Image(systemName: symbol(for: item.severity))
                    .font(.system(size: 11, weight: .black))
                    .foregroundStyle(tint)
                    .frame(width: 26, height: 26)
                    .background(
                        Circle()
                            .fill(tint.opacity(0.12))
                    )
                Rectangle()
                    .fill(tint.opacity(0.22))
                    .frame(width: 2, height: 28)
                    .clipShape(Capsule())
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(item.kindTitle)
                        .font(.system(size: 10, weight: .black, design: AgentPalette.interfaceFontDesign))
                        .foregroundStyle(tint)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Text(eventTimeText(item.createdAt))
                        .font(.system(size: 9, weight: .bold, design: AgentPalette.interfaceFontDesign))
                        .foregroundStyle(AgentPalette.tertiaryText)
                        .lineLimit(1)
                }

                Text(item.title)
                    .font(.system(size: 12, weight: .black, design: AgentPalette.interfaceFontDesign))
                    .foregroundStyle(AgentPalette.ink)
                    .lineLimit(2)
                    .minimumScaleFactor(0.82)

                if !item.detail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(item.detail)
                        .font(.system(size: 10, weight: .semibold, design: AgentPalette.interfaceFontDesign))
                        .foregroundStyle(AgentPalette.secondaryText)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.vertical, 10)
    }

    private func eventKindTitle(_ kind: ProjectEventKind) -> String {
        kind.rawValue
            .replacingOccurrences(of: "([a-z])([A-Z])", with: "$1 $2", options: .regularExpression)
            .capitalized
    }

    private func eventTimeText(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) {
            return DateFormatter.localizedString(from: date, dateStyle: .none, timeStyle: .short)
        }
        return DateFormatter.localizedString(from: date, dateStyle: .short, timeStyle: .none)
    }

    private func runStatusText(_ status: ToolRunStatus) -> String {
        switch status {
        case .pendingApproval: "Waiting approval"
        case .approved: "Approved"
        case .rejected: "Rejected"
        case .completed: "Completed"
        case .failed: "Failed"
        }
    }

    private var statusTint: Color {
        switch summary.statusKind {
        case .active, .done: AgentPalette.green
        case .waiting: AgentPalette.lilac
        case .blocked: AgentPalette.rose
        }
    }

    private var statusSymbol: String {
        switch summary.statusKind {
        case .active: "checkmark.seal.fill"
        case .waiting: "hourglass"
        case .blocked: "hand.raised.fill"
        case .done: "flag.checkered"
        }
    }

    private func tint(for severity: ProjectEventSeverity) -> Color {
        switch severity {
        case .info: AgentPalette.cyan
        case .running: AgentPalette.lilac
        case .success: AgentPalette.green
        case .warning: AgentPalette.indigo
        case .failure: AgentPalette.rose
        }
    }

    private func proofTint(for item: ProjectProofItem) -> Color {
        switch item.severity {
        case .failure:
            AgentPalette.rose
        case .warning:
            AgentPalette.indigo
        case .running:
            AgentPalette.lilac
        case .info:
            AgentPalette.cyan
        case .success:
            AgentPalette.green
        }
    }

    private func symbol(for severity: ProjectEventSeverity) -> String {
        switch severity {
        case .info: "info.circle.fill"
        case .running: "waveform"
        case .success: "checkmark.circle.fill"
        case .warning: "exclamationmark.circle.fill"
        case .failure: "xmark.octagon.fill"
        }
    }
}

private struct ProjectPrimarySurfaceKey: Equatable {
    let projectID: UUID
    let projectName: String
    let workspaceName: String
    let summary: ProjectMissionSummary
    let latestArtifactID: UUID?
    let latestArtifactPath: String?
    let latestArtifactTitle: String?
    let latestArtifactKindRawValue: String?
    let latestArtifactUpdatedAt: Date?
    let recommendedCommandIntent: ProjectCommandIntent
    let commandContext: String
    let commandRunBlocked: Bool
    let showsWorkspaceStatusStrip: Bool
    let runtimeStatusTitle: String
    let runtimeStatusDetail: String
    let runtimeStatusTone: WorkspaceStatusSnapshot.Tone
    let runtimeStatusChangedText: String?
    let runtimeStatusIsWorking: Bool
    let runtimeProgressSteps: [WorkspaceProgressStep]
    let autoContinueState: ProjectAutoContinueViewState
    let projectOSRunID: UUID?
    let projectOSRunStatusRawValue: String?
    let projectOSRunUpdatedAt: Date?
    let projectOSRunStepCount: Int
}

private struct ProjectIntakeSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft = ProjectIntakeDraft.empty
    let create: (ProjectIntakeDraft) -> Void

    private var canCreate: Bool {
        !draft.seedPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("New Project")
                            .font(.system(size: 24, weight: .black, design: AgentPalette.interfaceFontDesign))
                            .foregroundStyle(AgentPalette.ink)
                        Text("Tell NovaForge what you are making so it can name the project, set the mission, and choose real next tasks before the first run.")
                            .font(.system(size: 12.5, weight: .semibold, design: AgentPalette.interfaceFontDesign))
                            .foregroundStyle(AgentPalette.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    intakeField(
                        title: "What are you making?",
                        placeholder: "Example: a cozy farming roguelite, a chess puzzle app, a rhythm platformer",
                        text: $draft.projectKind,
                        symbol: "gamecontroller.fill",
                        identifier: "projectIntakeProjectKindField"
                    )

                    intakeField(
                        title: "Working title",
                        placeholder: "Optional, NovaForge can decide",
                        text: $draft.workingTitle,
                        symbol: "textformat",
                        identifier: "projectIntakeWorkingTitleField"
                    )

                    intakeField(
                        title: "Platform",
                        placeholder: "iPhone, iPad, web, Steam, controller-first, portrait mobile",
                        text: $draft.platform,
                        symbol: "iphone",
                        identifier: "projectIntakePlatformField"
                    )

                    intakeField(
                        title: "Style",
                        placeholder: "Premium glass, pixel art, brutalist, cozy, editorial, arcade neon",
                        text: $draft.style,
                        symbol: "paintpalette.fill",
                        identifier: "projectIntakeStyleField"
                    )

                    intakeField(
                        title: "Goal",
                        placeholder: "Prototype the first playable loop, ship a client demo, validate onboarding",
                        text: $draft.goal,
                        symbol: "target",
                        identifier: "projectIntakeGoalField"
                    )

                    intakeField(
                        title: "Starting priorities",
                        placeholder: "Core loop, first screen, saved data, performance, onboarding",
                        text: $draft.startingPriorities,
                        symbol: "list.bullet.clipboard.fill",
                        identifier: "projectIntakePrioritiesField"
                    )

                    intakeField(
                        title: "Player or user experience",
                        placeholder: "Fast, eerie, relaxing, competitive, kid-friendly, premium, difficult",
                        text: $draft.playerExperience,
                        symbol: "sparkles",
                        identifier: "projectIntakeExperienceField"
                    )

                    intakeField(
                        title: "Constraints",
                        placeholder: "Use SwiftUI, no backend, pixel art, local-only, 60 FPS, one-week prototype",
                        text: $draft.constraints,
                        symbol: "slider.horizontal.3",
                        identifier: "projectIntakeConstraintsField"
                    )

                    VStack(alignment: .leading, spacing: 8) {
                        Label("NovaForge will start with", systemImage: "checklist")
                            .font(.system(size: 12, weight: .black, design: AgentPalette.interfaceFontDesign))
                            .foregroundStyle(AgentPalette.ink)
                        VStack(alignment: .leading, spacing: 6) {
                            previewRow("Mission", draft.isEmpty ? "A focused build-and-proof project." : draft.missionText)
                            previewRow("Next step", draft.firstNextStep)
                            previewRow("Chosen tasks", draft.initialTaskPreview)
                        }
                    }
                    .padding(12)
                    .agentSurface(radius: 18, tint: AgentPalette.green.opacity(0.08))
                }
                .padding(18)
            }
            .scrollContentBackground(.hidden)
            .background(AgentBackground().ignoresSafeArea())
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        create(draft)
                    }
                    .disabled(!canCreate)
                }
            }
        }
        .accessibilityIdentifier("projectIntakeSheet")
    }

    private func intakeField(
        title: String,
        placeholder: String,
        text: Binding<String>,
        symbol: String,
        identifier: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Label(title, systemImage: symbol)
                .font(.system(size: 12, weight: .black, design: AgentPalette.interfaceFontDesign))
                .foregroundStyle(AgentPalette.ink)

            TextField(placeholder, text: text, axis: .vertical)
                .font(.system(size: 13, weight: .semibold, design: AgentPalette.interfaceFontDesign))
                .foregroundStyle(AgentPalette.ink)
                .textInputAutocapitalization(.sentences)
                .lineLimit(2...4)
                .padding(12)
                .frame(minHeight: 52, alignment: .topLeading)
                .agentControlSurface(radius: 14, tint: AgentPalette.cyan.opacity(0.08), selected: false)
                .accessibilityIdentifier(identifier)
        }
        .accessibilityElement(children: .contain)
    }

    private func previewRow(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 9, weight: .black, design: AgentPalette.interfaceFontDesign))
                .foregroundStyle(AgentPalette.tertiaryText)
                .textCase(.uppercase)
            Text(value)
                .font(.system(size: 11.5, weight: .semibold, design: AgentPalette.interfaceFontDesign))
                .foregroundStyle(AgentPalette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct ProjectEditSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: ProjectEditDraft
    let save: (ProjectEditDraft) -> Void

    init(project: Project, save: @escaping (ProjectEditDraft) -> Void) {
        _draft = State(initialValue: ProjectEditDraft(project: project))
        self.save = save
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Edit Project")
                            .font(.system(size: 24, weight: .black, design: AgentPalette.interfaceFontDesign))
                            .foregroundStyle(AgentPalette.ink)
                        Text("Update the project control center without turning the edit into a chat prompt.")
                            .font(.system(size: 12.5, weight: .semibold, design: AgentPalette.interfaceFontDesign))
                            .foregroundStyle(AgentPalette.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    editField(title: "Name", placeholder: "Project name", text: $draft.name, symbol: "textformat", identifier: "projectEditNameField")
                    editField(title: "Mission", placeholder: "What should this project accomplish?", text: $draft.mission, symbol: "scope", identifier: "projectEditMissionField", lineLimit: 3...6)
                    editField(title: "Workspace", placeholder: "Workspace folder", text: $draft.workspaceName, symbol: "folder.fill", identifier: "projectEditWorkspaceField")
                    editField(title: "Next step", placeholder: "The next task NovaForge should choose from", text: $draft.nextStep, symbol: "arrow.right.circle.fill", identifier: "projectEditNextStepField", lineLimit: 2...4)
                    editField(title: "Blocker", placeholder: "Optional active blocker", text: $draft.blocker, symbol: "exclamationmark.triangle.fill", identifier: "projectEditBlockerField", lineLimit: 2...4)

                    VStack(alignment: .leading, spacing: 8) {
                        Label("Status", systemImage: "gauge.with.dots.needle.bottom.50percent")
                            .font(.system(size: 12, weight: .black, design: AgentPalette.interfaceFontDesign))
                            .foregroundStyle(AgentPalette.ink)
                        Picker("Project status", selection: $draft.status) {
                            ForEach(ProjectState.allCases, id: \.self) { status in
                                Text(status.displayName).tag(status)
                            }
                        }
                        .pickerStyle(.segmented)
                        .accessibilityIdentifier("projectEditStatusPicker")
                    }
                    .padding(12)
                    .agentSurface(radius: 18, tint: AgentPalette.cyan.opacity(0.06))
                }
                .padding(18)
            }
            .scrollContentBackground(.hidden)
            .background(AgentBackground().ignoresSafeArea())
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        save(draft)
                    }
                    .disabled(!draft.isValid)
                }
            }
        }
        .accessibilityIdentifier("projectEditSheet")
    }

    private func editField(
        title: String,
        placeholder: String,
        text: Binding<String>,
        symbol: String,
        identifier: String,
        lineLimit: ClosedRange<Int> = 1...3
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Label(title, systemImage: symbol)
                .font(.system(size: 12, weight: .black, design: AgentPalette.interfaceFontDesign))
                .foregroundStyle(AgentPalette.ink)

            TextField(placeholder, text: text, axis: .vertical)
                .font(.system(size: 13, weight: .semibold, design: AgentPalette.interfaceFontDesign))
                .foregroundStyle(AgentPalette.ink)
                .textInputAutocapitalization(.sentences)
                .lineLimit(lineLimit)
                .padding(12)
                .frame(minHeight: 52, alignment: .topLeading)
                .agentControlSurface(radius: 14, tint: AgentPalette.cyan.opacity(0.08), selected: false)
                .accessibilityIdentifier(identifier)
        }
    }
}

private struct ProjectRunButtonStyle: ButtonStyle {
    let tint: Color
    let isDisabled: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(isDisabled ? tint : AgentPalette.ink)
            .agentGlass(radius: 14, interactive: !isDisabled, tint: tint.opacity(isDisabled ? 0.22 : 0.16))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(tint.opacity(configuration.isPressed ? 0.42 : isDisabled ? 0.28 : 0.18), lineWidth: configuration.isPressed ? 1.0 : 0.65)
            )
            .scaleEffect(configuration.isPressed ? 0.975 : 1)
            .animation(.spring(response: 0.18, dampingFraction: 0.72), value: configuration.isPressed)
    }
}

private struct ProjectStableSurface<Content: View>: View, Equatable {
    let key: ProjectPrimarySurfaceKey
    let content: () -> Content

    init(key: ProjectPrimarySurfaceKey, @ViewBuilder content: @escaping () -> Content) {
        self.key = key
        self.content = content
    }

    nonisolated static func == (lhs: ProjectStableSurface<Content>, rhs: ProjectStableSurface<Content>) -> Bool {
        lhs.key == rhs.key
    }

    var body: some View {
        content()
    }
}

private extension View {
    @ViewBuilder
    func projectMoreSurface(expanded: Bool) -> some View {
        if expanded {
            agentSurface(radius: 18, tint: AgentPalette.lilac.opacity(0.06))
        } else {
            self
        }
    }

    @ViewBuilder
    func projectScrollResponse(enabled: Bool) -> some View {
        if enabled {
            scrollTransition(.interactive, axis: .vertical) { content, phase in
                content
                    .scaleEffect(
                        x: 1,
                        y: phase.isIdentity ? 1 : 0.982,
                        anchor: phase.value < 0 ? .top : .bottom
                    )
                    .offset(y: phase.isIdentity ? 0 : phase.value * -3)
            }
        } else {
            self
        }
    }
}

/// Liquid journey rail for the Command Center: replaces the all-states chip
/// grid with a three-phase Plan → Build → Prove indicator. Completed phases
/// show a check, the active phase carries the execution tint and shimmers
/// while work is live, and trouble states sharpen the active stroke.
private struct NovaExecutionJourneyRail: View {
    let activePhase: Int
    let isLive: Bool
    let isTrouble: Bool
    let tint: Color

    private static let phases: [(title: String, symbol: String)] = [
        ("Plan", "list.bullet.clipboard.fill"),
        ("Build", "hammer.fill"),
        ("Prove", "checkmark.seal.fill")
    ]

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<Self.phases.count, id: \.self) { index in
                segment(index: index)
                if index < Self.phases.count - 1 {
                    connector(index: index)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Current phase: \(Self.phases[min(max(activePhase, 0), Self.phases.count - 1)].title)")
    }

    private func segment(index: Int) -> some View {
        let phase = Self.phases[index]
        let isActive = index == activePhase
        let isDone = index < activePhase
        let segmentTint: Color = isActive ? tint : (isDone ? AgentPalette.green : AgentPalette.tertiaryText)
        return HStack(spacing: 6) {
            Image(systemName: isDone ? "checkmark" : phase.symbol)
                .font(.system(size: 9, weight: .black))
                .foregroundStyle(segmentTint)

            if isActive && isLive {
                LiveShimmerText(
                    text: phase.title,
                    baseColor: segmentTint,
                    highlightColor: AgentPalette.ink,
                    font: .system(size: 10.5, weight: .black, design: AgentPalette.interfaceFontDesign)
                )
                .lineLimit(1)
            } else {
                Text(phase.title)
                    .font(.system(size: 10.5, weight: .black, design: AgentPalette.interfaceFontDesign))
                    .foregroundStyle(segmentTint)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, minHeight: 30)
        .background(
            (isActive ? tint : (isDone ? AgentPalette.green : AgentPalette.secondaryText))
                .opacity(isActive ? 0.13 : (isDone ? 0.08 : 0.05)),
            in: Capsule(style: .continuous)
        )
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(
                    isActive
                        ? tint.opacity(isTrouble ? 0.52 : 0.32)
                        : AgentPalette.border.opacity(isDone ? 0.20 : 0.10),
                    lineWidth: isActive ? 0.8 : 0.55
                )
        )
    }

    private func connector(index: Int) -> some View {
        Capsule(style: .continuous)
            .fill(index < activePhase ? AgentPalette.green.opacity(0.42) : AgentPalette.border.opacity(0.24))
            .frame(width: 10, height: 1.5)
    }
}

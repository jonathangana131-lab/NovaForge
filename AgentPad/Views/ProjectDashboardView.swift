import SwiftData
import SwiftUI

struct ProjectDashboardView: View {
    @Environment(\.modelContext) var modelContext
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    @Environment(\.dynamicTypeSize) var dynamicTypeSize
    @Query var dashboardRuns: [ToolRun]
    @Query var dashboardEvents: [ProjectEvent]
    @Query var dashboardArtifacts: [ProjectArtifact]
    @Query var dashboardTerminalCommands: [TerminalCommandRecord]
    @Query var dashboardFileChanges: [ProjectFileChange]
    @Query var dashboardProjectOSRuns: [ProjectOSRun]
    @State var selectedProofItem: ProjectProofItem?
    @State var highlightedProjectID: UUID?
    @State var cachedSummary: ProjectMissionSummary
    @State var cachedProjectConversations: [Conversation]
    @State var selectedCommandIntent: ProjectCommandIntent = .continueMission
    @State var selectedDetailScope: ProjectDetailScope = .review
    @State var commandContext = ""
    @State var selectedCommandProjectID: UUID?
    @State var showsAllProjects = false
    @State var showsProjectDetails = false
    @SceneStorage("ProjectDashboardView.selectedDetailScope") var restoredDetailScopeRawValue = "review"
    @SceneStorage("ProjectDashboardView.showsProjectDetails") var restoredShowsProjectDetails = false
    @State var presentedProjectSheet: ProjectSheetDestination?
    @State var confirmingProjectDelete = false
    @State var runStartFeedback = false
    @State var dashboardSaveError: String?
    @State var projectScrollStartedAt: Date?
    @State var didRunAutoScrollProfile = false
    @State var didPresentProjectIntakeDemo = false
    @State var didArmProjectFrameProbe = false
    @Namespace var projectSwitchGlassNamespace
    let project: Project
    let projects: [Project]
    let runtimeStatus: WorkspaceStatusSnapshot
    let autoContinueState: ProjectAutoContinueViewState
    let conversations: [Conversation]
    let closeDossier: () -> Void
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
    static let projectScrollTopID = "projectScrollTop"
    static let projectScrollBottomID = "projectScrollBottom"

    enum ProjectSheetDestination: String, Identifiable {
        case switcher
        case intake
        case edit

        var id: String { rawValue }
    }

    enum ProjectDetailScope: String, CaseIterable, Identifiable {
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

    enum DashboardExecutionState: String, CaseIterable, Identifiable {
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
            case .resumed: "Interrupted"
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
        closeDossier: @escaping () -> Void,
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
        self.closeDossier = closeDossier
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

    var projectEvents: [ProjectEvent] {
        dashboardEvents
    }

    var projectConversations: [Conversation] {
        cachedProjectConversations
    }

    var projectRuns: [ToolRun] {
        dashboardRuns
    }

    var projectArtifacts: [ProjectArtifact] {
        dashboardArtifacts
    }

    var projectFileChanges: [ProjectFileChange] {
        dashboardFileChanges
    }

    var projectOSRuns: [ProjectOSRun] {
        dashboardProjectOSRuns
    }

    var activeProjectOSRun: ProjectOSRun? {
        projectOSRuns.first { !$0.status.isTerminal } ?? projectOSRuns.first
    }

    var projectOSDisplaySteps: [ProjectOSDisplayStep] {
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

    var projectOSCompletedStepCount: Int {
        projectOSDisplaySteps.filter { $0.status == .completed }.count
    }

    var projectOSProgressFraction: Double {
        guard !projectOSDisplaySteps.isEmpty else { return 0 }
        return Double(projectOSCompletedStepCount) / Double(projectOSDisplaySteps.count)
    }

    var projectOSCurrentStep: ProjectOSDisplayStep? {
        projectOSDisplaySteps.first { $0.status == .running || $0.status == .planning || $0.status == .waiting || $0.status == .blocked } ??
            projectOSDisplaySteps.first { !$0.status.isTerminal } ??
            projectOSDisplaySteps.last
    }

    var projectOSNextStep: ProjectOSDisplayStep? {
        guard let current = projectOSCurrentStep,
              let index = projectOSDisplaySteps.firstIndex(where: { $0.id == current.id }) else {
            return projectOSDisplaySteps.first
        }
        return projectOSDisplaySteps.dropFirst(index + 1).first { !$0.status.isTerminal }
    }

    struct ProjectOSDisplayStep: Identifiable, Equatable {
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

    var adaptiveIntent: ProjectOSIntentSnapshot {
        if let activeProjectOSRun {
            return activeProjectOSRun.currentIntent
        }
        return ProjectOSIntentDeriver.makeIdleIntent(project: project)
    }


    var summary: ProjectMissionSummary {
        cachedSummary
    }

    var primarySurfaceKey: ProjectPrimarySurfaceKey {
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

    var dashboardSnapshotID: String {
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

    var sortedProjects: [Project] {
        projects.sorted { lhs, rhs in
            if lhs.id == project.id { return true }
            if rhs.id == project.id { return false }
            if lhs.lastActivityAt != rhs.lastActivityAt { return lhs.lastActivityAt > rhs.lastActivityAt }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    var visibleSwitcherProjects: [Project] {
        showsAllProjects ? sortedProjects : Array(sortedProjects.prefix(4))
    }

    var hiddenSwitcherProjectCount: Int {
        max(sortedProjects.count - visibleSwitcherProjects.count, 0)
    }

    static func mergedConversations(
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

    static func sortedProjectConversations(
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

    static func totalMessageCount(in conversations: [Conversation]) -> Int {
        conversations.reduce(into: 0) { total, conversation in
            total += conversation.messageCount
        }
    }

    static func makeSummary(
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

    func refreshDashboardSnapshot() {
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

    func syncRecommendedCommand(force: Bool = false) {
        guard force || selectedCommandProjectID != project.id else { return }
        selectedCommandProjectID = project.id
        selectedCommandIntent = recommendedCommandIntent
        commandContext = ""
    }

    func restoreSelectedAdaptiveSurface() {
        if let activeProjectOSRun {
            selectedDetailScope = detailScope(for: activeProjectOSRun.selectedAdaptiveSurface)
            return
        }
        if let restoredScope = ProjectDetailScope(rawValue: restoredDetailScopeRawValue) {
            selectedDetailScope = restoredScope
        }
    }

    func persistSelectedAdaptiveSurface(for scope: ProjectDetailScope) {
        restoredDetailScopeRawValue = scope.rawValue
        guard let activeProjectOSRun else { return }
        let surface = adaptiveSurface(for: scope)
        guard activeProjectOSRun.selectedAdaptiveSurface != surface else { return }
        activeProjectOSRun.selectedAdaptiveSurface = surface
        do {
            try modelContext.save()
        } catch {
            modelContext.rollback()
            dashboardSaveError = "NovaForge could not save that project surface selection. \(error.localizedDescription)"
        }
    }

    func adaptiveSurface(for scope: ProjectDetailScope) -> ProjectOSAdaptiveSurface {
        switch scope {
        case .review: return .now
        case .plan: return .plan
        case .evidence: return .proof
        case .timeline: return .history
        }
    }

    func detailScope(for surface: ProjectOSAdaptiveSurface) -> ProjectDetailScope {
        switch surface {
        case .now, .work: return .review
        case .plan: return .plan
        case .proof: return .evidence
        case .history: return .timeline
        }
    }

    var body: some View {
        let _ = AgentPerformance.bodyEvaluation("Project Dashboard Body")
        Group {
            if AgentPerformance.shouldProfileFrameRate {
                VStack(spacing: 0) {
                    projectPinnedCommandCenter
                        .padding(.horizontal)
                        .padding(.top, 6)
                        .padding(.bottom, 4)

                    projectPerformanceProfileSurface
                }
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    projectPinnedActionDock
                        .padding(.horizontal)
                        .padding(.top, 6)
                        .padding(.bottom, 4)
                }
            } else {
                ZStack(alignment: .top) {
                    VStack(spacing: 0) {
                        projectPinnedCommandCenter
                            .padding(.horizontal)
                            .padding(.top, 6)
                            .padding(.bottom, 4)
                            .zIndex(3)

                        ScrollViewReader { scrollProxy in
                            ScrollView(showsIndicators: false) {
                                LazyVStack(alignment: .leading, spacing: 14) {
                                    Color.clear
                                        .frame(height: 1)
                                        .id(Self.projectScrollTopID)
                                        .accessibilityHidden(true)

                                    projectOSControlCenter

                                    projectOSWorkspaceSection

                                    Color.clear
                                        .frame(height: 1)
                                        .id(Self.projectScrollBottomID)
                                        .accessibilityHidden(true)
                                }
                                .padding(.horizontal)
                                .padding(.top, 6)
                                .padding(.bottom, 12)
                            }
                            .scrollContentBackground(.hidden)
                            .scrollDismissesKeyboard(.interactively)
                            .simultaneousGesture(projectScrollInstrumentationGesture)
                            .task(id: project.id) {
                                await runProjectAutoScrollProfileIfNeeded(scrollProxy)
                            }
                        }
                    }

                    projectFrameRateProbe
                }
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    projectPinnedActionDock
                        .padding(.horizontal)
                        .padding(.top, 6)
                        .padding(.bottom, 4)
                }
            }
        }
        .accessibilityIdentifier("projectDashboard")
        .onAppear {
            AgentPerformance.event("Project Dashboard Appear")
            highlightedProjectID = project.id
            showsProjectDetails = restoredShowsProjectDetails
            syncRecommendedCommand(force: true)
            restoreSelectedAdaptiveSurface()
            presentProjectIntakeDemoIfNeeded()
            armProjectFrameProbeAfterSettle()
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
            armProjectFrameProbeAfterSettle()
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
        .sheet(item: $presentedProjectSheet) { destination in
            switch destination {
            case .switcher:
                projectSwitcherSheet
            case .intake:
                ProjectIntakeSheet { draft in
                    createProject(draft)
                    presentedProjectSheet = nil
                }
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
            case .edit:
                ProjectEditSheet(project: project) { draft in
                    updateProject(project, draft)
                    presentedProjectSheet = nil
                }
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
            }
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
        .alert(
            "Project Save Error",
            isPresented: Binding(
                get: { dashboardSaveError != nil },
                set: { if !$0 { dashboardSaveError = nil } }
            )
        ) {
            Button("OK", role: .cancel) { dashboardSaveError = nil }
        } message: {
            Text(dashboardSaveError ?? "NovaForge could not save that project dashboard change.")
        }
    }

    @ViewBuilder
    var projectPerformanceProfileSurface: some View {
        ZStack(alignment: .top) {
            ScrollViewReader { scrollProxy in
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 0) {
                        Color.clear
                            .frame(height: 1)
                            .id(Self.projectScrollTopID)
                            .accessibilityHidden(true)

                        VStack(alignment: .leading, spacing: 8) {
                            Text("Mission Dossier")
                                .font(.system(size: 12, weight: .black, design: AgentPalette.interfaceFontDesign))
                                .foregroundStyle(AgentPalette.primaryAccent)
                            Text(project.name)
                                .font(.system(size: 20, weight: .black, design: AgentPalette.interfaceFontDesign))
                                .foregroundStyle(AgentPalette.ink)
                                .lineLimit(2)
                            Text(summary.review.headline)
                                .font(.system(size: 11, weight: .semibold, design: AgentPalette.interfaceFontDesign))
                                .foregroundStyle(AgentPalette.secondaryText)
                                .lineLimit(2)
                        }
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(AgentPalette.surfaceElevated, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("projectOSControlCenter")

                        Color.clear
                            .frame(height: 760)
                            .accessibilityHidden(true)

                        Color.clear
                            .frame(height: 1)
                            .id(Self.projectScrollBottomID)
                            .accessibilityHidden(true)
                    }
                    .padding(.horizontal)
                    .padding(.top, 10)
                    .padding(.bottom, BottomDockMetrics.scrollClearance)
                }
                .scrollContentBackground(.hidden)
                .simultaneousGesture(projectScrollInstrumentationGesture)
                .task(id: project.id) {
                    await runProjectAutoScrollProfileIfNeeded(scrollProxy)
                }
            }

            projectFrameRateProbe
        }
    }

    var projectScrollInstrumentationGesture: some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { _ in
                if AgentPerformance.shouldProfileFrameRate,
                   ProcessInfo.processInfo.arguments.contains("--auto-project-scroll"),
                   didRunAutoScrollProfile {
                    // The UI test performs manual swipes and captures after the
                    // deterministic auto-scroll window. Those interactions are
                    // proof-gathering overhead, not product idle/scroll health,
                    // so stop the sampler before screenshot/dismissal work can
                    // poison the Project idle averages.
                    didArmProjectFrameProbe = false
                    projectScrollStartedAt = nil
                    return
                }
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

    func presentProjectIntakeDemoIfNeeded() {
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--project-intake-demo"), !didPresentProjectIntakeDemo {
            didPresentProjectIntakeDemo = true
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(350))
                presentedProjectSheet = .intake
            }
            return
        }
        if arguments.contains("--project-edit-demo"), !didPresentProjectIntakeDemo {
            didPresentProjectIntakeDemo = true
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(350))
                presentedProjectSheet = .edit
            }
            return
        }
        if arguments.contains("--project-delete-confirm-demo"), !didPresentProjectIntakeDemo {
            didPresentProjectIntakeDemo = true
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(700))
                confirmingProjectDelete = true
            }
        }
    }

    func runProjectAutoScrollProfileIfNeeded(_ proxy: ScrollViewProxy) async {
        guard !didRunAutoScrollProfile else { return }
        guard ProcessInfo.processInfo.arguments.contains("--auto-project-scroll") else { return }
        didRunAutoScrollProfile = true
        try? await Task.sleep(for: .milliseconds(3_400))
        guard !Task.isCancelled else { return }

        projectScrollStartedAt = Date()
        AgentPerformance.event("Project Scroll Started")
        withAnimation(projectAutoScrollAnimation(duration: 1.1)) {
            proxy.scrollTo(Self.projectScrollBottomID, anchor: .bottom)
        }
        try? await Task.sleep(for: .milliseconds(850))
        guard !Task.isCancelled else { return }

        withAnimation(projectAutoScrollAnimation(duration: 1.0)) {
            proxy.scrollTo(Self.projectScrollTopID, anchor: .top)
        }
        try? await Task.sleep(for: .milliseconds(650))
        guard !Task.isCancelled else { return }

        if let startedAt = projectScrollStartedAt {
            let durationMilliseconds = max(0, Date().timeIntervalSince(startedAt) * 1_000)
            AgentPerformance.value("Project Scroll Duration ms", durationMilliseconds)
        }
        AgentPerformance.event("Project Scroll Completed")
        projectScrollStartedAt = nil
        if AgentPerformance.shouldProfileFrameRate {
            didArmProjectFrameProbe = false
        }
    }

    func armProjectFrameProbeAfterSettle() {
        guard AgentPerformance.shouldProfileFrameRate else {
            didArmProjectFrameProbe = true
            return
        }
        didArmProjectFrameProbe = false
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(1_600))
            guard !Task.isCancelled else { return }
            didArmProjectFrameProbe = true
        }
    }

    func projectAutoScrollAnimation(duration: TimeInterval) -> Animation? {
        guard !reduceMotion else { return nil }
        if AgentPerformance.shouldProfileFrameRate {
            return nil
        }
        guard !AgentPerformance.prefersReducedVisualEffects else { return nil }
        return .smooth(duration: duration)
    }

    @ViewBuilder
    var projectFrameRateProbe: some View {
        if AgentPerformance.shouldProfileFrameRate {
            PerformanceFrameProbe(
                surface: projectScrollStartedAt == nil ? .projectIdle : .projectScroll,
                isActive: isVisibleForFrameProfiling && didArmProjectFrameProbe
            )
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    var dashboardExecutionState: DashboardExecutionState {
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

    var hasProjectOSProofEvidence: Bool {
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

    var projectOSStatusText: String {
        projectOSStatus.displayName
    }

    var projectOSTint: Color {
        projectOSTint(for: projectOSStatus)
    }

    var projectOSStatusSymbol: String {
        projectOSStatusSymbol(for: projectOSStatus)
    }


    var projectOSExecutionStateDetail: String {
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

    var projectOSEvidenceSummaryText: String {
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

    var projectOSLogSummaryText: String {
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


    var projectOSMissionText: String {
        let runMission = activeProjectOSRun?.mission.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !runMission.isEmpty { return runMission }
        return missionCopy
    }

    var projectOSCurrentActionText: String {
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

    var projectOSCurrentReasonText: String {
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

    var projectOSCurrentCommandText: String {
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

    var projectOSNextStepText: String {
        if let next = projectOSNextStep?.title, !next.isEmpty { return next }
        if let runNext = activeProjectOSRun?.nextStep.trimmingCharacters(in: .whitespacesAndNewlines),
           !runNext.isEmpty {
            return runNext
        }
        return summary.workflowSpine.nextActionDetail
    }

    var projectOSProofText: String {
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

    var projectOSBlockerTitle: String {
        if autoContinueState.state == .blocked { return "Local Model / Auto-continue" }
        switch projectOSStatus {
        case .waiting: return "Waiting"
        case .blocked, .failed: return "Blocker"
        case .stopped: return "Stopped"
        default: return "Blockers"
        }
    }

    var projectOSBlockerText: String {
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

    var projectOSBlockerSymbol: String {
        if autoContinueState.state == .blocked { return "hand.raised.fill" }
        switch projectOSStatus {
        case .waiting: return "hourglass"
        case .blocked, .failed: return "exclamationmark.triangle.fill"
        case .stopped: return "pause.circle.fill"
        default: return "checkmark.circle.fill"
        }
    }

    var projectOSBlockerTint: Color {
        if autoContinueState.state == .blocked { return AgentPalette.rose }
        switch projectOSStatus {
        case .waiting: return AgentPalette.cyan
        case .blocked, .failed: return AgentPalette.rose
        case .stopped: return AgentPalette.lilac
        default: return AgentPalette.green
        }
    }

    func projectOSTint(for status: ProjectOSRunStatus) -> Color {
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

    func dashboardExecutionTint(_ state: DashboardExecutionState) -> Color {
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


    func projectOSStatusSymbol(for status: ProjectOSRunStatus) -> String {
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

    func projectOSStepTint(_ status: ProjectOSStepStatus) -> Color {
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

    func projectOSStepSymbol(_ key: String) -> String {
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

}

struct ProjectPrimarySurfaceKey: Equatable {
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
    @State private var showingDetails = false
    @FocusState private var briefFocused: Bool
    let create: (ProjectIntakeDraft) -> Void

    private var canCreate: Bool {
        !draft.seedPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("New Project")
                            .font(.system(size: 24, weight: .black, design: AgentPalette.interfaceFontDesign))
                            .foregroundStyle(AgentPalette.ink)
                        Text("One sentence is enough. NovaForge names the project, writes the mission, and picks the first tasks.")
                            .font(.system(size: 12.5, weight: .semibold, design: AgentPalette.interfaceFontDesign))
                            .foregroundStyle(AgentPalette.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    // The brief IS the intake. Everything else is inferred,
                    // and the optional details below only refine it.
                    TextField(
                        "A cozy farming roguelite for iPhone. A chess puzzle app. A rhythm platformer with neon style…",
                        text: $draft.projectKind,
                        axis: .vertical
                    )
                    .font(.system(size: 15, weight: .semibold, design: AgentPalette.interfaceFontDesign))
                    .foregroundStyle(AgentPalette.ink)
                    .textInputAutocapitalization(.sentences)
                    .lineLimit(4...8)
                    .padding(14)
                    .frame(minHeight: 108, alignment: .topLeading)
                    .agentControlSurface(radius: 16, tint: AgentPalette.cyan.opacity(0.10), selected: briefFocused)
                    .focused($briefFocused)
                    .accessibilityIdentifier("projectIntakeProjectKindField")

                    if canCreate {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("NovaForge will start with", systemImage: "checklist")
                                .font(.system(size: 12, weight: .black, design: AgentPalette.interfaceFontDesign))
                                .foregroundStyle(AgentPalette.ink)
                            VStack(alignment: .leading, spacing: 6) {
                                previewRow("Mission", draft.missionText)
                                previewRow("Next step", draft.firstNextStep)
                                previewRow("Chosen tasks", draft.initialTaskPreview)
                            }
                        }
                        .padding(12)
                        .agentSurface(radius: 18, tint: AgentPalette.green.opacity(0.08))
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    }

                    DisclosureGroup(isExpanded: $showingDetails) {
                        VStack(alignment: .leading, spacing: 14) {
                            intakeField(
                                title: "Working title",
                                placeholder: "Optional, NovaForge can decide",
                                text: $draft.workingTitle,
                                symbol: "textformat",
                                identifier: "projectIntakeWorkingTitleField"
                            )
                            intakeField(
                                title: "Platform",
                                placeholder: "iPhone, iPad, web, Steam, controller-first",
                                text: $draft.platform,
                                symbol: "iphone",
                                identifier: "projectIntakePlatformField"
                            )
                            intakeField(
                                title: "Style",
                                placeholder: "Premium glass, pixel art, cozy, arcade neon",
                                text: $draft.style,
                                symbol: "paintpalette.fill",
                                identifier: "projectIntakeStyleField"
                            )
                            intakeField(
                                title: "Goal",
                                placeholder: "Prototype the first playable loop, ship a demo",
                                text: $draft.goal,
                                symbol: "target",
                                identifier: "projectIntakeGoalField"
                            )
                            intakeField(
                                title: "Starting priorities",
                                placeholder: "Core loop, first screen, saved data",
                                text: $draft.startingPriorities,
                                symbol: "list.bullet.clipboard.fill",
                                identifier: "projectIntakePrioritiesField"
                            )
                            intakeField(
                                title: "Experience",
                                placeholder: "Fast, eerie, relaxing, competitive, premium",
                                text: $draft.playerExperience,
                                symbol: "sparkles",
                                identifier: "projectIntakeExperienceField"
                            )
                            intakeField(
                                title: "Constraints",
                                placeholder: "SwiftUI, no backend, local-only, 60 FPS",
                                text: $draft.constraints,
                                symbol: "slider.horizontal.3",
                                identifier: "projectIntakeConstraintsField"
                            )
                        }
                        .padding(.top, 10)
                    } label: {
                        Label("Refine the brief (optional)", systemImage: "slider.horizontal.2.square")
                            .font(.system(size: 12, weight: .black, design: AgentPalette.interfaceFontDesign))
                            .foregroundStyle(AgentPalette.secondaryText)
                    }
                    .tint(AgentPalette.secondaryText)
                    .accessibilityIdentifier("projectIntakeDetailsDisclosure")
                }
                .padding(18)
                .animation(.smooth(duration: 0.25), value: canCreate)
            }
            .scrollContentBackground(.hidden)
            .scrollDismissesKeyboard(.interactively)
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
            .task {
                try? await Task.sleep(for: .milliseconds(450))
                briefFocused = true
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

/// The one solid-fill control in the app: the project's ignition switch.
/// Filled accent capsule with a soft accent bloom — everything else on the
/// dashboard is line-drawn glass, so this button owns the light.
struct ProjectRunButtonStyle: ButtonStyle {
    let tint: Color
    let isDisabled: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(isDisabled ? AgentPalette.secondaryText : AgentPalette.pearl)
            .background(
                Capsule(style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: isDisabled
                                ? [AgentPalette.controlFill, AgentPalette.controlFill]
                                : [tint, tint.opacity(0.82)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
            )
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(
                        isDisabled ? AgentPalette.controlBorder.opacity(0.6) : tint.opacity(configuration.isPressed ? 0.9 : 0.45),
                        lineWidth: 0.9
                    )
            )
            .shadow(
                color: isDisabled || AgentPerformance.prefersReducedVisualEffects ? .clear : tint.opacity(configuration.isPressed ? 0.20 : 0.38),
                radius: configuration.isPressed ? 6 : 12,
                x: 0,
                y: 3
            )
            .scaleEffect(configuration.isPressed ? 0.965 : 1)
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

extension View {

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
struct NovaExecutionJourneyRail: View {
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

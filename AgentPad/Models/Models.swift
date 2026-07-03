import Foundation
import SwiftData

/// A lightweight in-app toast for transient feedback (saves, copies, model loads,
/// recoverable errors). Lives in Models (compiled by both the app and test
/// targets) so AgentRuntime — which is also compiled by both — can queue toasts.
struct AgentToast: Identifiable, Equatable {
    enum Tone {
        case success, error, info
    }

    let id = UUID()
    let message: String
    var tone: Tone = .info
    var retryAction: (() -> Void)?

    static func == (lhs: AgentToast, rhs: AgentToast) -> Bool { lhs.id == rhs.id }
}

struct WorkspaceProgressStep: Identifiable, Equatable, Sendable {
    enum State: String, Equatable, Sendable {
        case pending
        case current
        case done
        case blocked
    }

    var id: String
    var title: String
    var detail: String
    var symbolName: String
    var state: State
}

enum ChatRole: String, Codable, CaseIterable, Sendable {
    case user
    case assistant
    case system
    case tool
}

enum ToolRunStatus: String, Codable, CaseIterable, Sendable {
    case pendingApproval
    case approved
    case rejected
    case completed
    case failed
}

enum ProjectState: String, Codable, CaseIterable, Sendable {
    case active
    case running
    case needsReview
    case blocked
    case completed

    var displayName: String {
        switch self {
        case .active: "Active"
        case .running: "Running"
        case .needsReview: "Needs Review"
        case .blocked: "Blocked"
        case .completed: "Complete"
        }
    }
}

enum ProjectOSRunStatus: String, Codable, CaseIterable, Sendable {
    case idle
    case planning
    case running
    case waiting
    case blocked
    case failed
    case completed
    case stopped

    var displayName: String {
        switch self {
        case .idle: "Idle"
        case .planning: "Planning"
        case .running: "Running"
        case .waiting: "Waiting"
        case .blocked: "Blocked"
        case .failed: "Failed"
        case .completed: "Completed"
        case .stopped: "Stopped"
        }
    }

    var isTerminal: Bool {
        switch self {
        case .completed, .failed, .stopped:
            return true
        case .idle, .planning, .running, .waiting, .blocked:
            return false
        }
    }
}

enum ProjectOSStepStatus: String, Codable, CaseIterable, Sendable {
    case pending
    case planning
    case running
    case waiting
    case blocked
    case completed
    case failed
    case skipped
    case stopped

    var displayName: String {
        switch self {
        case .pending: "Pending"
        case .planning: "Planning"
        case .running: "Running"
        case .waiting: "Waiting"
        case .blocked: "Blocked"
        case .completed: "Done"
        case .failed: "Failed"
        case .skipped: "Skipped"
        case .stopped: "Stopped"
        }
    }

    var isTerminal: Bool {
        switch self {
        case .completed, .failed, .skipped, .stopped:
            return true
        case .pending, .planning, .running, .waiting, .blocked:
            return false
        }
    }
}

enum ProjectOSRunOrigin: String, Codable, CaseIterable, Sendable {
    case manual
    case autoContinued
    case recovered
    case fixture
}

enum ProjectOSIntentMode: String, Codable, CaseIterable, Sendable {
    case idle
    case planning
    case readingContext
    case inspectingFiles
    case editingCode
    case runningTool
    case runningCommand
    case runningTests
    case waitingApproval
    case blocked
    case verifyingOutput
    case capturingScreenshot
    case producingProof
    case summarizingCompletion
    case completedProof
    case stoppedResumable

    var displayName: String {
        switch self {
        case .idle: "Idle"
        case .planning: "Planning"
        case .readingContext: "Reading Context"
        case .inspectingFiles: "Inspecting"
        case .editingCode: "Editing"
        case .runningTool: "Using Tool"
        case .runningCommand: "Running Command"
        case .runningTests: "Testing"
        case .waitingApproval: "Waiting Approval"
        case .blocked: "Blocked"
        case .verifyingOutput: "Verifying"
        case .capturingScreenshot: "Capturing"
        case .producingProof: "Producing Proof"
        case .summarizingCompletion: "Summarizing"
        case .completedProof: "Proof Complete"
        case .stoppedResumable: "Stopped"
        }
    }
}

enum ProjectOSIntentSource: String, Codable, CaseIterable, Sendable {
    case runState
    case stepState
    case runtimeTrace
    case projectEvent
    case terminalCommand
    case toolApproval
    case fileChange
    case artifact
    case proof
    case recovery
    case summary
    case fixture

    var displayName: String {
        switch self {
        case .runState: "Run state"
        case .stepState: "Step state"
        case .runtimeTrace: "Runtime trace"
        case .projectEvent: "Project event"
        case .terminalCommand: "Terminal command"
        case .toolApproval: "Tool approval"
        case .fileChange: "File change"
        case .artifact: "Artifact"
        case .proof: "Proof"
        case .recovery: "Recovery"
        case .summary: "Summary"
        case .fixture: "Fixture"
        }
    }
}

enum ProjectOSIntentConfidence: String, Codable, CaseIterable, Sendable {
    case observed
    case inferred
    case fallback

    var displayName: String {
        switch self {
        case .observed: "Observed"
        case .inferred: "Inferred"
        case .fallback: "Fallback"
        }
    }
}

enum ProjectOSWorkObjectKind: String, Codable, CaseIterable, Sendable {
    case none
    case project
    case step
    case file
    case command
    case tool
    case testBuildGate
    case artifact
    case approval
    case blocker
    case proof

    var displayName: String {
        switch self {
        case .none: "None"
        case .project: "Project"
        case .step: "Step"
        case .file: "File"
        case .command: "Command"
        case .tool: "Tool"
        case .testBuildGate: "Check"
        case .artifact: "Artifact"
        case .approval: "Approval"
        case .blocker: "Blocker"
        case .proof: "Proof"
        }
    }
}

enum ProjectOSAdaptiveSurface: String, Codable, CaseIterable, Sendable {
    case now
    case plan
    case work
    case proof
    case history

    var displayName: String {
        switch self {
        case .now: "Now"
        case .plan: "Plan"
        case .work: "Work"
        case .proof: "Proof"
        case .history: "History"
        }
    }
}

struct ProjectOSIntentSnapshot: Codable, Equatable, Identifiable, Sendable {
    var id: String {
        "\(timestamp.timeIntervalSince1970)-\(mode.rawValue)-\(objectKind.rawValue)-\(objectTitle)-\(objectDetail)"
    }

    var mode: ProjectOSIntentMode
    var source: ProjectOSIntentSource
    var confidence: ProjectOSIntentConfidence
    var summary: String
    var objectKind: ProjectOSWorkObjectKind
    var objectTitle: String
    var objectDetail: String
    var filePath: String
    var command: String
    var toolName: String
    var testBuildGate: String
    var artifactPath: String
    var blocker: String
    var proof: String
    var reason: String
    var recommendedAction: String
    var timestamp: Date

    var semanticKey: String {
        [
            mode.rawValue,
            objectKind.rawValue,
            objectTitle,
            objectDetail,
            filePath,
            command,
            toolName,
            testBuildGate,
            artifactPath,
            blocker,
            proof,
            summary,
            reason,
            recommendedAction
        ].joined(separator: "|")
    }

    var preferredSurface: ProjectOSAdaptiveSurface {
        switch mode {
        case .planning, .readingContext:
            return .plan
        case .inspectingFiles, .editingCode, .runningTool, .runningCommand, .runningTests, .waitingApproval, .blocked, .verifyingOutput, .capturingScreenshot, .stoppedResumable:
            return .work
        case .producingProof, .summarizingCompletion, .completedProof:
            return .proof
        case .idle:
            return .now
        }
    }

    static func compacted(_ snapshot: ProjectOSIntentSnapshot) -> ProjectOSIntentSnapshot {
        ProjectOSIntentSnapshot(
            mode: snapshot.mode,
            source: snapshot.source,
            confidence: snapshot.confidence,
            summary: compact(snapshot.summary, limit: 180),
            objectKind: snapshot.objectKind,
            objectTitle: compact(snapshot.objectTitle, limit: 120),
            objectDetail: compact(snapshot.objectDetail, limit: 500),
            filePath: compact(snapshot.filePath, limit: 1_000),
            command: compact(snapshot.command, limit: 1_000),
            toolName: compact(snapshot.toolName, limit: 120),
            testBuildGate: compact(snapshot.testBuildGate, limit: 200),
            artifactPath: compact(snapshot.artifactPath, limit: 1_000),
            blocker: compact(snapshot.blocker, limit: 500),
            proof: compact(snapshot.proof, limit: 500),
            reason: compact(snapshot.reason, limit: 500),
            recommendedAction: compact(snapshot.recommendedAction, limit: 240),
            timestamp: snapshot.timestamp
        )
    }

    static func idle(project: Project, now: Date = Date()) -> ProjectOSIntentSnapshot {
        ProjectOSIntentSnapshot(
            mode: .idle,
            source: .summary,
            confidence: .fallback,
            summary: "ProjectOS is ready for the next project run.",
            objectKind: .project,
            objectTitle: project.name,
            objectDetail: project.mission,
            filePath: "",
            command: "",
            toolName: "",
            testBuildGate: "",
            artifactPath: "",
            blocker: project.blocker,
            proof: "",
            reason: "No active ProjectOS run is in progress.",
            recommendedAction: project.nextStep,
            timestamp: now
        )
    }

    private static func compact(_ text: String, limit: Int) -> String {
        let oneLine = text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard oneLine.count > limit else { return oneLine }
        return String(oneLine.prefix(max(0, limit - 1))) + "..."
    }
}

enum ProjectAutoContinueState: String, Codable, CaseIterable, Sendable {
    case idle
    case countdown
    case paused
    case blocked
    case started

    var displayName: String {
        switch self {
        case .idle: "Ready"
        case .countdown: "Countdown"
        case .paused: "Paused"
        case .blocked: "Stopped"
        case .started: "Started"
        }
    }
}

struct ProjectAutoContinueEvaluation: Equatable, Sendable {
    enum Action: Equatable, Sendable {
        case disabled
        case waiting
        case schedule
        case stop
    }

    var action: Action
    var sourceEventID: String?
    var intent: ProjectCommandIntent
    var title: String
    var detail: String
}

struct ProjectAutoContinueViewState: Equatable, Sendable {
    var isEnabled: Bool
    var isPaused: Bool
    var isCountingDown: Bool
    var remainingSeconds: Int
    var state: ProjectAutoContinueState
    var title: String
    var detail: String

    static let disabled = ProjectAutoContinueViewState(
        isEnabled: false,
        isPaused: false,
        isCountingDown: false,
        remainingSeconds: 0,
        state: .idle,
        title: "Auto-continue off",
        detail: "Enable it for this project when the next safe step should start automatically."
    )
}

enum ProjectAutoContinuePolicy {
    static let countdownSeconds = 5

    static func evaluate(
        project: Project,
        summary: ProjectMissionSummary,
        settings: AgentSettings?,
        runtimeIsWorking: Bool,
        hasPendingRuntimeApproval: Bool,
        runCompleted: Bool,
        runFailedOrPaused: Bool,
        hasUsableProviderCredential: Bool,
        latestRunEventID: String?
    ) -> ProjectAutoContinueEvaluation {
        let intent = summary.missionContract.recommendedIntent
        guard project.autoContinueEnabled else {
            return ProjectAutoContinueEvaluation(
                action: .disabled,
                sourceEventID: latestRunEventID,
                intent: intent,
                title: "Auto-continue off",
                detail: "Enable it when this project should keep moving after safe completions."
            )
        }

        if project.autoContinuePaused {
            return ProjectAutoContinueEvaluation(
                action: .stop,
                sourceEventID: latestRunEventID,
                intent: intent,
                title: "Auto-continue paused",
                detail: "Resume the project manually when ready."
            )
        }

        if runtimeIsWorking {
            return ProjectAutoContinueEvaluation(
                action: .waiting,
                sourceEventID: latestRunEventID,
                intent: intent,
                title: "Run in progress",
                detail: "Auto-continue waits for the current project run to settle."
            )
        }

        if hasPendingRuntimeApproval || summary.pendingApprovalCount > 0 {
            return ProjectAutoContinueEvaluation(
                action: .stop,
                sourceEventID: latestRunEventID,
                intent: intent,
                title: "Approval needed",
                detail: "Review the pending approval before autonomous continuation resumes."
            )
        }

        if runFailedOrPaused || summary.failureCount > 0 || !summary.blocker.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return ProjectAutoContinueEvaluation(
                action: .stop,
                sourceEventID: latestRunEventID,
                intent: intent,
                title: "Blocked by evidence",
                detail: summary.blocker.isEmpty ? "Review the failed run before another automatic step." : summary.blocker
            )
        }

        if summary.review.hasWrongProjectRisk {
            return ProjectAutoContinueEvaluation(
                action: .stop,
                sourceEventID: latestRunEventID,
                intent: intent,
                title: "Wrong-project risk",
                detail: summary.review.primaryFinding?.detail ?? "Confirm the project workspace before auto-continue resumes."
            )
        }

        if project.autoContinueFailureStreak >= 2 {
            return ProjectAutoContinueEvaluation(
                action: .stop,
                sourceEventID: latestRunEventID,
                intent: intent,
                title: "Repeated failure guard",
                detail: "NovaForge stopped automatic retries after repeated failed evidence."
            )
        }

        if !hasUsableProviderCredential {
            let provider = settings?.provider.displayName ?? "the selected provider"
            return ProjectAutoContinueEvaluation(
                action: .stop,
                sourceEventID: latestRunEventID,
                intent: intent,
                title: "Provider setup needed",
                detail: "Add credentials for \(provider) before auto-continue can start another run."
            )
        }

        if project.status == .completed || summary.statusKind == .done {
            return ProjectAutoContinueEvaluation(
                action: .stop,
                sourceEventID: latestRunEventID,
                intent: intent,
                title: "Final review reached",
                detail: "The project is marked complete, so NovaForge will not auto-start more work."
            )
        }

        if summary.missionContract.phase == .contract {
            return ProjectAutoContinueEvaluation(
                action: .stop,
                sourceEventID: latestRunEventID,
                intent: intent,
                title: "Requirements unclear",
                detail: "Clarify the mission before NovaForge continues automatically."
            )
        }

        if summary.missionContract.decisionLabel == "Ready to review" {
            return ProjectAutoContinueEvaluation(
                action: .stop,
                sourceEventID: latestRunEventID,
                intent: intent,
                title: "Final review ready",
                detail: "Proof is ready for human review before more autonomous work."
            )
        }

        guard runCompleted else {
            return ProjectAutoContinueEvaluation(
                action: .waiting,
                sourceEventID: latestRunEventID,
                intent: intent,
                title: "Waiting for completion",
                detail: "Auto-continue starts only after a clean project run completes."
            )
        }

        guard let latestRunEventID else {
            return ProjectAutoContinueEvaluation(
                action: .waiting,
                sourceEventID: nil,
                intent: intent,
                title: "Waiting for durable run proof",
                detail: "A run-completed timeline event is required before auto-start."
            )
        }

        if project.autoContinueSourceEventIDString == latestRunEventID,
           project.autoContinueState == .started {
            return ProjectAutoContinueEvaluation(
                action: .waiting,
                sourceEventID: latestRunEventID,
                intent: intent,
                title: "Already handled",
                detail: "This completed run already scheduled an automatic next step."
            )
        }

        return ProjectAutoContinueEvaluation(
            action: .schedule,
            sourceEventID: latestRunEventID,
            intent: intent,
            title: "Auto-continue ready",
            detail: summary.nextStep
        )
    }
}

enum ProjectEventKind: String, Codable, CaseIterable, Sendable {
    case projectCreated
    case projectSelected
    case projectRenamed
    case migrationLinked
    case conversationStarted
    case conversationContinued
    case conversationRenamed
    case conversationDeleted
    case promptQueued
    case agentPlanCreated
    case agentProofCreated
    case missionCheckpoint
    case responseSaved
    case toolQueued
    case toolApprovalRequested
    case toolApproved
    case toolRejected
    case toolCompleted
    case toolFailed
    case runCompleted
    case runFailed
    case runLogDeleted
    case runPaused
    case artifactCreated
    case artifactPreviewed
    case fileChanged
    case terminalCommand
    case workspaceChanged
    case settingsChanged
    case autoContinueEnabled
    case autoContinueDisabled
    case autoContinueScheduled
    case autoContinueStarted
    case autoContinuePaused
}

enum ProjectEventSeverity: String, Codable, CaseIterable, Sendable {
    case info
    case running
    case success
    case warning
    case failure
}

enum ProjectEventSourceType: String, Codable, CaseIterable, Sendable {
    case conversation
    case message
    case toolRun
    case terminalCommand
    case artifact
    case workspace
    case settings
    case system
}

enum ProjectArtifactKind: String, Codable, CaseIterable, Sendable {
    case html
    case swiftGame
    case gameSpec
    case assetPack
    case xcodeProject
    case exportBundle
    case web
    case document
    case code
    case other

    var workspaceType: WorkspaceArtifactType {
        switch self {
        case .html, .web:
            return .html
        case .swiftGame:
            return .swiftGame
        case .gameSpec:
            return .gameSpec
        case .assetPack:
            return .assetPack
        case .xcodeProject:
            return .xcodeProject
        case .exportBundle:
            return .exportBundle
        case .code:
            return .source
        case .document:
            return .document
        case .other:
            return .other
        }
    }
}

enum TerminalCommandStatus: String, Codable, CaseIterable, Sendable {
    case completed
    case failed
}

@Model
final class Project {
    var id: UUID
    var name: String
    var mission: String
    var statusRawValue: String
    var workspaceName: String
    var blocker: String
    var nextStep: String
    var autoContinueEnabledValue: Bool?
    var autoContinuePausedValue: Bool?
    var autoContinueStateRawValue: String?
    var autoContinueSourceEventIDString: String?
    var autoContinueDecision: String?
    var autoContinueFailureStreakValue: Int?
    var autoContinueUpdatedAt: Date?
    var createdAt: Date
    var updatedAt: Date
    var lastActivityAt: Date

    @Relationship(deleteRule: .nullify, inverse: \Conversation.project)
    var conversations: [Conversation]
    @Relationship(deleteRule: .nullify, inverse: \ToolRun.project)
    var toolRuns: [ToolRun]
    @Relationship(deleteRule: .cascade, inverse: \ProjectEvent.project)
    var events: [ProjectEvent]
    @Relationship(deleteRule: .cascade, inverse: \ProjectArtifact.project)
    var artifacts: [ProjectArtifact]
    @Relationship(deleteRule: .cascade, inverse: \TerminalCommandRecord.project)
    var terminalCommands: [TerminalCommandRecord]
    @Relationship(deleteRule: .cascade, inverse: \ProjectFileChange.project)
    var fileChanges: [ProjectFileChange]
    @Relationship(deleteRule: .cascade, inverse: \ProjectOSRun.project)
    var projectOSRuns: [ProjectOSRun]

    var status: ProjectState {
        get { ProjectState(rawValue: statusRawValue) ?? .active }
        set { statusRawValue = newValue.rawValue }
    }

    var autoContinueEnabled: Bool {
        get { autoContinueEnabledValue ?? false }
        set { autoContinueEnabledValue = newValue }
    }

    var autoContinuePaused: Bool {
        get { autoContinuePausedValue ?? false }
        set { autoContinuePausedValue = newValue }
    }

    var autoContinueState: ProjectAutoContinueState {
        get { ProjectAutoContinueState(rawValue: autoContinueStateRawValue ?? "") ?? .idle }
        set { autoContinueStateRawValue = newValue.rawValue }
    }

    var autoContinueFailureStreak: Int {
        get { autoContinueFailureStreakValue ?? 0 }
        set { autoContinueFailureStreakValue = max(0, newValue) }
    }

    init(
        name: String = ProjectBootstrap.defaultProjectName,
        mission: String = "Build and verify useful work in NovaForge.",
        workspaceName: String = "Default",
        status: ProjectState = .active,
        now: Date = Date()
    ) {
        self.id = UUID()
        self.name = name
        self.mission = mission
        self.statusRawValue = status.rawValue
        self.workspaceName = workspaceName
        self.blocker = ""
        self.nextStep = "Send the next project request."
        self.autoContinueEnabledValue = false
        self.autoContinuePausedValue = false
        self.autoContinueStateRawValue = ProjectAutoContinueState.idle.rawValue
        self.autoContinueSourceEventIDString = nil
        self.autoContinueDecision = nil
        self.autoContinueFailureStreakValue = 0
        self.autoContinueUpdatedAt = nil
        self.createdAt = now
        self.updatedAt = now
        self.lastActivityAt = now
        self.conversations = []
        self.toolRuns = []
        self.events = []
        self.artifacts = []
        self.terminalCommands = []
        self.fileChanges = []
        self.projectOSRuns = []
    }
}

@Model
final class ProjectEvent {
    var id: UUID
    var kindRawValue: String
    var severityRawValue: String
    var title: String
    var detail: String
    var createdAt: Date
    var sourceTypeRawValue: String?
    var sourceIDString: String?
    var metadataJSON: String?
    var project: Project?

    var kind: ProjectEventKind {
        get { ProjectEventKind(rawValue: kindRawValue) ?? .projectCreated }
        set { kindRawValue = newValue.rawValue }
    }

    var severity: ProjectEventSeverity {
        get { ProjectEventSeverity(rawValue: severityRawValue) ?? .info }
        set { severityRawValue = newValue.rawValue }
    }

    var sourceType: ProjectEventSourceType? {
        get {
            guard let sourceTypeRawValue else { return nil }
            return ProjectEventSourceType(rawValue: sourceTypeRawValue)
        }
        set { sourceTypeRawValue = newValue?.rawValue }
    }

    var metadata: [String: String] {
        Self.decodeMetadata(metadataJSON)
    }

    var missionOSCheckpoint: MissionOSCheckpoint? {
        MissionOSCheckpoint(event: self)
    }

    init(
        project: Project?,
        kind: ProjectEventKind,
        title: String,
        detail: String = "",
        severity: ProjectEventSeverity = .info,
        sourceType: ProjectEventSourceType? = nil,
        sourceID: UUID? = nil,
        metadataJSON: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = UUID()
        self.kindRawValue = kind.rawValue
        self.severityRawValue = severity.rawValue
        self.title = Self.compact(title, limit: 120)
        self.detail = Self.compact(detail, limit: 1_200)
        self.createdAt = createdAt
        self.sourceTypeRawValue = sourceType?.rawValue
        self.sourceIDString = sourceID?.uuidString
        self.metadataJSON = metadataJSON
        self.project = project
    }

    private static func compact(_ text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        return String(text.prefix(limit - 1)) + "..."
    }

    private static func decodeMetadata(_ json: String?) -> [String: String] {
        guard let json,
              let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: String] else {
            return [:]
        }
        return dictionary
    }
}

@Model
final class ProjectArtifact {
    var id: UUID
    var path: String
    var title: String
    var descriptionText: String?
    var kindRawValue: String
    var typeRawValue: String?
    var previewModeRawValue: String?
    var orientationPreferenceRawValue: String?
    var aspectRatioValue: Double?
    var statusRawValue: String?
    var assetsJSON: String?
    var generatedFilesJSON: String?
    var exportStatusRawValue: String?
    var errorsJSON: String?
    var warningsJSON: String?
    var version: Int?
    var historyJSON: String?
    var createdAt: Date
    var updatedAt: Date
    var sourceToolRunIDString: String?
    var project: Project?

    var kind: ProjectArtifactKind {
        get { ProjectArtifactKind(rawValue: kindRawValue) ?? .other }
        set { kindRawValue = newValue.rawValue }
    }

    var type: WorkspaceArtifactType {
        get { WorkspaceArtifactType(rawValue: typeRawValue ?? "") ?? kind.workspaceType }
        set { typeRawValue = newValue.rawValue }
    }

    var previewMode: ArtifactPreviewMode {
        get { ArtifactPreviewMode(rawValue: previewModeRawValue ?? "") ?? WorkspaceArtifact(path: path).previewMode }
        set { previewModeRawValue = newValue.rawValue }
    }

    var orientationPreference: ArtifactOrientationPreference {
        get { ArtifactOrientationPreference(rawValue: orientationPreferenceRawValue ?? "") ?? WorkspaceArtifact(path: path).orientationPreference }
        set { orientationPreferenceRawValue = newValue.rawValue }
    }

    var status: WorkspaceArtifactStatus {
        get { WorkspaceArtifactStatus(rawValue: statusRawValue ?? "") ?? .generated }
        set { statusRawValue = newValue.rawValue }
    }

    var exportStatus: WorkspaceArtifactStatus {
        get { WorkspaceArtifactStatus(rawValue: exportStatusRawValue ?? "") ?? status }
        set { exportStatusRawValue = newValue.rawValue }
    }

    init(
        project: Project?,
        path: String,
        kind: ProjectArtifactKind = .other,
        type: WorkspaceArtifactType? = nil,
        description: String = "",
        previewMode: ArtifactPreviewMode? = nil,
        orientationPreference: ArtifactOrientationPreference? = nil,
        aspectRatio: Double? = nil,
        status: WorkspaceArtifactStatus = .generated,
        assets: [String] = [],
        generatedFiles: [String] = [],
        exportStatus: WorkspaceArtifactStatus? = nil,
        errors: [String] = [],
        warnings: [String] = [],
        version: Int = 1,
        history: [String] = [],
        sourceToolRunID: UUID? = nil,
        now: Date = Date()
    ) {
        let workspaceArtifact = WorkspaceArtifact(path: path)
        let resolvedType = type ?? workspaceArtifact.artifactType
        self.id = UUID()
        self.path = path
        self.title = URL(fileURLWithPath: path).lastPathComponent
        self.descriptionText = description
        self.kindRawValue = kind == .other ? Self.kind(for: resolvedType).rawValue : kind.rawValue
        self.typeRawValue = resolvedType.rawValue
        self.previewModeRawValue = (previewMode ?? workspaceArtifact.previewMode).rawValue
        self.orientationPreferenceRawValue = (orientationPreference ?? workspaceArtifact.orientationPreference).rawValue
        self.aspectRatioValue = aspectRatio
        self.statusRawValue = status.rawValue
        self.assetsJSON = Self.encodeStringArray(assets)
        self.generatedFilesJSON = Self.encodeStringArray(generatedFiles)
        self.exportStatusRawValue = (exportStatus ?? status).rawValue
        self.errorsJSON = Self.encodeStringArray(errors)
        self.warningsJSON = Self.encodeStringArray(warnings)
        self.version = max(1, version)
        self.historyJSON = Self.encodeStringArray(history)
        self.createdAt = now
        self.updatedAt = now
        self.sourceToolRunIDString = sourceToolRunID?.uuidString
        self.project = project
    }

    static func kind(for type: WorkspaceArtifactType) -> ProjectArtifactKind {
        switch type {
        case .html: return .web
        case .swiftGame: return .swiftGame
        case .gameSpec: return .gameSpec
        case .assetPack: return .assetPack
        case .xcodeProject: return .xcodeProject
        case .exportBundle: return .exportBundle
        case .source: return .code
        case .document: return .document
        case .other: return .other
        }
    }

    private static func encodeStringArray(_ values: [String]) -> String {
        guard let data = try? JSONEncoder().encode(values),
              let text = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return text
    }
}

@Model
final class TerminalCommandRecord {
    var id: UUID
    var command: String
    var output: String
    var statusRawValue: String
    var workspaceName: String
    var createdAt: Date
    var completedAt: Date
    var durationMs: Double
    var sourceToolRunIDString: String?
    var project: Project?

    var status: TerminalCommandStatus {
        get { TerminalCommandStatus(rawValue: statusRawValue) ?? .completed }
        set { statusRawValue = newValue.rawValue }
    }

    init(
        project: Project?,
        command: String,
        output: String,
        status: TerminalCommandStatus,
        workspaceName: String,
        startedAt: Date = Date(),
        completedAt: Date = Date(),
        durationMs: Double,
        sourceToolRunID: UUID? = nil
    ) {
        self.id = UUID()
        self.command = Self.compact(command, limit: 2_000)
        self.output = PersistedPayloadBudget.compactToolRunOutput(output)
        self.statusRawValue = status.rawValue
        self.workspaceName = workspaceName
        self.createdAt = startedAt
        self.completedAt = completedAt
        self.durationMs = durationMs
        self.sourceToolRunIDString = sourceToolRunID?.uuidString
        self.project = project
    }

    private static func compact(_ text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        return String(text.prefix(limit - 1)) + "..."
    }
}

@Model
final class ProjectFileChange {
    var id: UUID
    var action: String
    var path: String
    var createdAt: Date
    var sourceEventIDString: String?
    var sourceToolRunIDString: String?
    var sourceTerminalCommandIDString: String?
    var project: Project?

    init(
        project: Project?,
        action: String,
        path: String,
        sourceEventID: UUID? = nil,
        sourceToolRunID: UUID? = nil,
        sourceTerminalCommandID: UUID? = nil,
        createdAt: Date = Date()
    ) {
        self.id = UUID()
        self.action = Self.compact(action, limit: 120)
        self.path = Self.compact(path, limit: 1_000)
        self.createdAt = createdAt
        self.sourceEventIDString = sourceEventID?.uuidString
        self.sourceToolRunIDString = sourceToolRunID?.uuidString
        self.sourceTerminalCommandIDString = sourceTerminalCommandID?.uuidString
        self.project = project
    }

    private static func compact(_ text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        return String(text.prefix(limit - 1)) + "..."
    }
}

@Model
final class ProjectOSRun {
    var id: UUID
    var projectName: String
    var mission: String
    var statusRawValue: String
    var planningState: String
    var currentAction: String
    var currentCommand: String
    var nextStep: String
    var latestEventTitle: String
    var latestEventDetail: String
    var changedFilesSummary: String
    var artifactsSummary: String
    var proofSummary: String
    var blockerReason: String
    var waitingReason: String
    var failureReason: String
    var resumeState: String
    var intentModeRawValue: String = ProjectOSIntentMode.idle.rawValue
    var intentSourceRawValue: String = ProjectOSIntentSource.summary.rawValue
    var intentConfidenceRawValue: String = ProjectOSIntentConfidence.fallback.rawValue
    var intentSummary: String = "ProjectOS is ready for the next project run."
    var intentObjectKindRawValue: String = ProjectOSWorkObjectKind.project.rawValue
    var intentObjectTitle: String = ""
    var intentObjectDetail: String = ""
    var intentFilePath: String = ""
    var intentCommand: String = ""
    var intentToolName: String = ""
    var intentTestBuildGate: String = ""
    var intentArtifactPath: String = ""
    var intentBlocker: String = ""
    var intentProof: String = ""
    var intentReason: String = "No active ProjectOS run is in progress."
    var intentRecommendedAction: String = "Send the next project request."
    var intentUpdatedAt: Date?
    var intentHistoryJSON: String = "[]"
    var selectedAdaptiveSurfaceRawValue: String = ProjectOSAdaptiveSurface.now.rawValue
    var sourceConversationIDString: String?
    var originRawValue: String
    var progressEventCount: Int
    var createdAt: Date
    var updatedAt: Date
    var startedAt: Date?
    var completedAt: Date?
    @Relationship(deleteRule: .cascade, inverse: \ProjectOSStep.run)
    var steps: [ProjectOSStep]
    var project: Project?

    var status: ProjectOSRunStatus {
        get { ProjectOSRunStatus(rawValue: statusRawValue) ?? .idle }
        set { statusRawValue = newValue.rawValue }
    }

    var origin: ProjectOSRunOrigin {
        get { ProjectOSRunOrigin(rawValue: originRawValue) ?? .manual }
        set { originRawValue = newValue.rawValue }
    }

    var currentIntent: ProjectOSIntentSnapshot {
        ProjectOSIntentSnapshot(
            mode: ProjectOSIntentMode(rawValue: intentModeRawValue) ?? .idle,
            source: ProjectOSIntentSource(rawValue: intentSourceRawValue) ?? .summary,
            confidence: ProjectOSIntentConfidence(rawValue: intentConfidenceRawValue) ?? .fallback,
            summary: intentSummary,
            objectKind: ProjectOSWorkObjectKind(rawValue: intentObjectKindRawValue) ?? .none,
            objectTitle: intentObjectTitle,
            objectDetail: intentObjectDetail,
            filePath: intentFilePath,
            command: intentCommand,
            toolName: intentToolName,
            testBuildGate: intentTestBuildGate,
            artifactPath: intentArtifactPath,
            blocker: intentBlocker,
            proof: intentProof,
            reason: intentReason,
            recommendedAction: intentRecommendedAction,
            timestamp: intentUpdatedAt ?? updatedAt
        )
    }

    var intentHistory: [ProjectOSIntentSnapshot] {
        get { Self.decodeIntentHistory(intentHistoryJSON) }
        set { intentHistoryJSON = Self.encodeIntentHistory(newValue) }
    }

    var selectedAdaptiveSurface: ProjectOSAdaptiveSurface {
        get { ProjectOSAdaptiveSurface(rawValue: selectedAdaptiveSurfaceRawValue) ?? currentIntent.preferredSurface }
        set { selectedAdaptiveSurfaceRawValue = newValue.rawValue }
    }

    init(
        project: Project?,
        projectName: String,
        mission: String,
        status: ProjectOSRunStatus = .planning,
        origin: ProjectOSRunOrigin = .manual,
        sourceConversationID: UUID? = nil,
        now: Date = Date()
    ) {
        self.id = UUID()
        self.projectName = Self.compact(projectName, limit: 120)
        self.mission = Self.compact(mission, limit: 1_000)
        self.statusRawValue = status.rawValue
        self.planningState = status == .planning ? "Creating agent plan" : status.displayName
        self.currentAction = "Creating the agent plan"
        self.currentCommand = ""
        self.nextStep = "Read project context"
        self.latestEventTitle = "ProjectOS run created"
        self.latestEventDetail = "Waiting for the first runtime event."
        self.changedFilesSummary = ""
        self.artifactsSummary = ""
        self.proofSummary = ""
        self.blockerReason = ""
        self.waitingReason = ""
        self.failureReason = ""
        self.resumeState = ""
        self.intentModeRawValue = ProjectOSIntentMode.idle.rawValue
        self.intentSourceRawValue = ProjectOSIntentSource.summary.rawValue
        self.intentConfidenceRawValue = ProjectOSIntentConfidence.fallback.rawValue
        self.intentSummary = "ProjectOS is ready for the next project run."
        self.intentObjectKindRawValue = ProjectOSWorkObjectKind.project.rawValue
        self.intentObjectTitle = Self.compact(projectName, limit: 120)
        self.intentObjectDetail = Self.compact(mission, limit: 500)
        self.intentFilePath = ""
        self.intentCommand = ""
        self.intentToolName = ""
        self.intentTestBuildGate = ""
        self.intentArtifactPath = ""
        self.intentBlocker = ""
        self.intentProof = ""
        self.intentReason = "No active ProjectOS run is in progress."
        self.intentRecommendedAction = "Send the next project request."
        self.intentUpdatedAt = now
        self.intentHistoryJSON = "[]"
        self.selectedAdaptiveSurfaceRawValue = ProjectOSAdaptiveSurface.now.rawValue
        self.sourceConversationIDString = sourceConversationID?.uuidString
        self.originRawValue = origin.rawValue
        self.progressEventCount = 0
        self.createdAt = now
        self.updatedAt = now
        self.startedAt = now
        self.completedAt = nil
        self.steps = []
        self.project = project
    }

    func applyIntent(_ snapshot: ProjectOSIntentSnapshot) {
        let normalized = Self.normalizedIntent(snapshot)
        let previousKey = currentIntent.semanticKey
        intentModeRawValue = normalized.mode.rawValue
        intentSourceRawValue = normalized.source.rawValue
        intentConfidenceRawValue = normalized.confidence.rawValue
        intentSummary = normalized.summary
        intentObjectKindRawValue = normalized.objectKind.rawValue
        intentObjectTitle = normalized.objectTitle
        intentObjectDetail = normalized.objectDetail
        intentFilePath = normalized.filePath
        intentCommand = normalized.command
        intentToolName = normalized.toolName
        intentTestBuildGate = normalized.testBuildGate
        intentArtifactPath = normalized.artifactPath
        intentBlocker = normalized.blocker
        intentProof = normalized.proof
        intentReason = normalized.reason
        intentRecommendedAction = normalized.recommendedAction
        intentUpdatedAt = normalized.timestamp
        selectedAdaptiveSurfaceRawValue = normalized.preferredSurface.rawValue

        var history = intentHistory
        if history.isEmpty || previousKey != normalized.semanticKey {
            history.append(normalized)
            if history.count > 32 {
                history.removeFirst(history.count - 32)
            }
            intentHistory = history
        }
    }

    private static func compact(_ text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        return String(text.prefix(max(0, limit - 1))) + "..."
    }

    private static func normalizedIntent(_ snapshot: ProjectOSIntentSnapshot) -> ProjectOSIntentSnapshot {
        ProjectOSIntentSnapshot.compacted(snapshot)
    }

    private static func decodeIntentHistory(_ json: String) -> [ProjectOSIntentSnapshot] {
        guard let data = json.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([ProjectOSIntentSnapshot].self, from: data) else {
            return []
        }
        return decoded
    }

    private static func encodeIntentHistory(_ history: [ProjectOSIntentSnapshot]) -> String {
        let capped = Array(history.suffix(32))
        guard let data = try? JSONEncoder().encode(capped),
              let json = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return json
    }
}

@Model
final class ProjectOSStep {
    var id: UUID
    var key: String
    var orderIndex: Int
    var title: String
    var detail: String
    var reason: String
    var statusRawValue: String
    var command: String
    var proof: String
    var resultSummary: String
    var createdAt: Date
    var updatedAt: Date
    var startedAt: Date?
    var completedAt: Date?
    var run: ProjectOSRun?

    var status: ProjectOSStepStatus {
        get { ProjectOSStepStatus(rawValue: statusRawValue) ?? .pending }
        set { statusRawValue = newValue.rawValue }
    }

    init(
        run: ProjectOSRun?,
        key: String,
        orderIndex: Int,
        title: String,
        detail: String,
        reason: String,
        status: ProjectOSStepStatus = .pending,
        command: String = "",
        now: Date = Date()
    ) {
        self.id = UUID()
        self.key = Self.compact(key, limit: 80)
        self.orderIndex = orderIndex
        self.title = Self.compact(title, limit: 120)
        self.detail = Self.compact(detail, limit: 500)
        self.reason = Self.compact(reason, limit: 500)
        self.statusRawValue = status.rawValue
        self.command = Self.compact(command, limit: 500)
        self.proof = ""
        self.resultSummary = ""
        self.createdAt = now
        self.updatedAt = now
        self.startedAt = status == .pending ? nil : now
        self.completedAt = status.isTerminal ? now : nil
        self.run = run
    }

    private static func compact(_ text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        return String(text.prefix(max(0, limit - 1))) + "..."
    }
}

@Model
final class Conversation {
    var id: UUID
    var title: String
    var createdAt: Date
    var updatedAt: Date
    var messageCount: Int
    var lastMessagePreview: String
    var hasUserMessages: Bool
    @Relationship(deleteRule: .cascade, inverse: \ChatMessage.conversation)
    var messages: [ChatMessage]
    var project: Project?

    init(title: String = "NovaForge", project: Project? = nil) {
        self.id = UUID()
        self.title = title
        self.createdAt = Date()
        self.updatedAt = Date()
        self.messageCount = 0
        self.lastMessagePreview = ""
        self.hasUserMessages = false
        self.messages = []
        self.project = project
    }

    func appendMessage(_ message: ChatMessage, updateTimestamp: Date = Date()) {
        message.conversation = self
        let inserted = !messages.contains(where: { $0.id == message.id })
        if inserted {
            messages.append(message)
        }
        if inserted {
            record(message, updateTimestamp: updateTimestamp)
        } else {
            refreshMessageMetadata(updateTimestamp: updateTimestamp)
        }
    }

    func appendMessages(_ newMessages: [ChatMessage], updateTimestamp: Date = Date()) {
        for message in newMessages {
            message.conversation = self
            if !messages.contains(where: { $0.id == message.id }) {
                messages.append(message)
            }
        }
        refreshMessageMetadata(updateTimestamp: updateTimestamp)
    }

    func refreshMessageMetadata(updateTimestamp: Date? = nil) {
        messageCount = messages.count
        hasUserMessages = messages.contains { $0.role == .user }
        if let latest = messages.max(by: { $0.createdAt < $1.createdAt }) {
            lastMessagePreview = Self.previewText(for: latest.content)
        } else {
            lastMessagePreview = ""
        }
        if let updateTimestamp {
            updatedAt = updateTimestamp
        }
    }

    private func record(_ message: ChatMessage, updateTimestamp: Date) {
        messageCount += 1
        if message.role == .user {
            hasUserMessages = true
        }
        if !message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lastMessagePreview = Self.previewText(for: message.content)
        }
        updatedAt = updateTimestamp
    }

    private static func previewText(for content: String) -> String {
        let oneLine = content
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !oneLine.isEmpty else { return "No messages yet" }
        if oneLine.count <= 150 {
            return oneLine
        }
        let end = oneLine.index(oneLine.startIndex, offsetBy: 150)
        return String(oneLine[..<end]) + "…"
    }
}

struct APIToolCall: Codable, Hashable, Sendable {
    let id: String
    let type: String
    let function: APIFunctionCall
}

struct APIFunctionCall: Codable, Hashable, Sendable {
    let name: String
    let arguments: String
}

enum PersistedPayloadBudget {
    static let maxMessageContentCharacters = 24_000
    static let maxToolMessageContentCharacters = 12_000
    static let maxToolRunOutputCharacters = 16_000
    static let maxToolRunArgumentsCharacters = 8_000
    static let maxToolCallArgumentsCharacters = 6_000
    static let maxToolCallsJSONCharacters = 24_000

    static func compactMessageContent(_ content: String, role: ChatRole) -> String {
        let limit = role == .tool ? maxToolMessageContentCharacters : maxMessageContentCharacters
        return compact(content, label: "persisted \(role.rawValue) message", limit: limit)
    }

    static func compactToolRunArguments(_ argumentsJSON: String) -> String {
        compactJSONArguments(argumentsJSON, label: "persisted tool arguments", limit: maxToolRunArgumentsCharacters)
    }

    static func compactToolRunOutput(_ output: String) -> String {
        compact(output, label: "persisted tool output", limit: maxToolRunOutputCharacters)
    }

    static func compactToolCallsJSON(_ json: String?) -> String? {
        guard let json else { return nil }
        guard json.count > maxToolCallsJSONCharacters || containsOversizedToolArguments(json) else { return json }

        if let data = json.data(using: .utf8),
           let calls = try? JSONDecoder().decode([APIToolCall].self, from: data) {
            let compacted = calls.map { call in
                let arguments = compactJSONArguments(
                    call.function.arguments,
                    label: "persisted \(call.function.name) arguments",
                    limit: maxToolCallArgumentsCharacters
                )
                return APIToolCall(
                    id: call.id,
                    type: call.type,
                    function: APIFunctionCall(name: call.function.name, arguments: arguments)
                )
            }
            if let compactedData = try? JSONEncoder().encode(compacted),
               let compactedJSON = String(data: compactedData, encoding: .utf8),
               compactedJSON.count <= maxToolCallsJSONCharacters {
                return compactedJSON
            }
        }

        return compactJSONArguments(json, label: "persisted tool_calls JSON", limit: maxToolCallsJSONCharacters)
    }

    static func compactBeforeSave(in context: ModelContext) {
        if let messages = try? context.fetch(FetchDescriptor<ChatMessage>()) {
            for message in messages {
                let compactedContent = compactMessageContent(message.content, role: message.role)
                if compactedContent != message.content {
                    message.content = compactedContent
                }

                let compactedToolCallsJSON = compactToolCallsJSON(message.toolCallsJSON)
                if compactedToolCallsJSON != message.toolCallsJSON {
                    message.toolCallsJSON = compactedToolCallsJSON
                }
            }
        }

        if let runs = try? context.fetch(FetchDescriptor<ToolRun>()) {
            for run in runs {
                let compactedArguments = compactToolRunArguments(run.argumentsJSON)
                if compactedArguments != run.argumentsJSON {
                    run.argumentsJSON = compactedArguments
                }

                let compactedOutput = compactToolRunOutput(run.output)
                if compactedOutput != run.output {
                    run.output = compactedOutput
                }
            }
        }
    }

    private static func containsOversizedToolArguments(_ json: String) -> Bool {
        guard let data = json.data(using: .utf8),
              let calls = try? JSONDecoder().decode([APIToolCall].self, from: data) else {
            return json.count > maxToolCallsJSONCharacters
        }
        return calls.contains { $0.function.arguments.count > maxToolCallArgumentsCharacters }
    }

    private static func compactJSONArguments(_ json: String, label: String, limit: Int) -> String {
        guard json.count > limit else { return json }

        if let data = json.data(using: .utf8),
           var object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            var changed = false
            for key in ["contents", "content", "text", "replacement", "new_string", "old_string", "command", "query", "pattern"] {
                guard let value = object[key] as? String, value.count > 1_200 else { continue }
                object[key] = compact(value, label: "\(label).\(key)", limit: 1_200)
                changed = true
            }

            if changed,
               JSONSerialization.isValidJSONObject(object),
               let compactedData = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]),
               let compacted = String(data: compactedData, encoding: .utf8),
               compacted.count <= limit {
                return compacted
            }

            let preservedKeys = ["path", "from", "to", "file", "cwd", "language", "name"]
            var fallback = preservedKeys.reduce(into: [String: Any]()) { partial, key in
                if let value = object[key] as? String {
                    partial[key] = compact(value, label: "\(label).\(key)", limit: 900)
                }
            }
            fallback["__novaforge_compacted"] = "\(label) exceeded the local persistence budget; inspect workspace files or rerun the tool for full detail."
            fallback["preview"] = compact(json, label: label, limit: 1_200)
            if JSONSerialization.isValidJSONObject(fallback),
               let fallbackData = try? JSONSerialization.data(withJSONObject: fallback, options: [.sortedKeys, .withoutEscapingSlashes]),
               let encoded = String(data: fallbackData, encoding: .utf8),
               encoded.count <= limit {
                return encoded
            }
        }

        let fallback: [String: String] = [
            "__novaforge_compacted": "\(label) exceeded the local persistence budget; inspect workspace files or rerun the tool for full detail.",
            "preview": compact(json, label: label, limit: min(1_200, max(512, limit - 512)))
        ]
        if let data = try? JSONSerialization.data(withJSONObject: fallback, options: [.sortedKeys, .withoutEscapingSlashes]),
           let encoded = String(data: data, encoding: .utf8),
           encoded.count <= limit {
            return encoded
        }
        return compact(json, label: label, limit: limit)
    }

    private static func compact(_ content: String, label: String, limit: Int) -> String {
        guard content.count > limit else { return content }
        let note = "\n\n[NovaForge compacted this \(label) before saving local history to keep launch, Chat, and Runs responsive on iPhone.]\n\n"
        let budget = max(512, limit - note.count - 48)
        let headCount = max(256, Int(Double(budget) * 0.70))
        let tailCount = max(128, budget - headCount)
        let omitted = max(0, content.count - headCount - tailCount)
        return "\(content.prefix(headCount))\(note)--- \(omitted) characters omitted ---\n\(content.suffix(tailCount))"
    }
}

@Model
final class ChatMessage {
    var id: UUID
    var roleRawValue: String
    var content: String
    var createdAt: Date
    var conversation: Conversation?
    var toolCallID: String?
    var toolCallsJSON: String?

    var role: ChatRole {
        get { ChatRole(rawValue: roleRawValue) ?? .assistant }
        set { roleRawValue = newValue.rawValue }
    }

    var toolCalls: [APIToolCall]? {
        guard let json = toolCallsJSON,
              let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode([APIToolCall].self, from: data)
    }

    init(
        role: ChatRole,
        content: String,
        toolCallID: String? = nil,
        toolCallsJSON: String? = nil,
        conversation: Conversation? = nil
    ) {
        self.id = UUID()
        self.roleRawValue = role.rawValue
        self.content = PersistedPayloadBudget.compactMessageContent(content, role: role)
        self.toolCallID = toolCallID
        self.toolCallsJSON = PersistedPayloadBudget.compactToolCallsJSON(toolCallsJSON)
        self.createdAt = Date()
        self.conversation = conversation
    }
}

@Model
final class ToolRun {
    var id: UUID
    var name: String
    var argumentsJSON: String
    var output: String
    var statusRawValue: String
    var createdAt: Date
    var completedAt: Date?
    var requiresApproval: Bool
    var isMutating: Bool
    var project: Project?

    var status: ToolRunStatus {
        get { ToolRunStatus(rawValue: statusRawValue) ?? .completed }
        set { statusRawValue = newValue.rawValue }
    }

    init(
        name: String,
        argumentsJSON: String,
        output: String = "",
        status: ToolRunStatus = .completed,
        requiresApproval: Bool = false,
        isMutating: Bool = false,
        project: Project? = nil
    ) {
        self.id = UUID()
        self.name = name
        self.argumentsJSON = PersistedPayloadBudget.compactToolRunArguments(argumentsJSON)
        self.output = PersistedPayloadBudget.compactToolRunOutput(output)
        self.statusRawValue = status.rawValue
        self.createdAt = Date()
        self.completedAt = nil
        self.requiresApproval = requiresApproval
        self.isMutating = isMutating
        self.project = project
    }
}

@Model
final class AgentSettings {
    var id: UUID
    var providerRawValue: String?
    var modelID: String
    var customChatCompletionsURL: String?
    var autoApproveWrites: Bool
    var activeWorkspaceName: String
    var activeProjectIDString: String?
    var temperature: Double
    var customSystemPrompt: String?
    var createdAt: Date
    var updatedAt: Date

    var provider: AIProvider {
        get { AIProvider(rawValue: providerRawValue ?? "") ?? .openAI }
        set {
            let oldProvider = AIProvider(rawValue: providerRawValue ?? "") ?? .openAI
            providerRawValue = newValue.rawValue
            if oldProvider != newValue, !newValue.modelOptions.contains(modelID) {
                modelID = newValue.defaultModel
            }
        }
    }

    @discardableResult
    func switchProvider(to newProvider: AIProvider) -> Bool {
        let oldProvider = provider
        let oldModelID = modelID
        providerRawValue = newProvider.rawValue

        let trimmedModel = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        if oldProvider != newProvider {
            if newProvider.modelOptions.contains(trimmedModel) {
                modelID = trimmedModel
            } else {
                modelID = newProvider.defaultModel
            }
        } else {
            repairStaleModelSelection()
        }

        let changed = oldProvider != newProvider || oldModelID != modelID
        if changed {
            updatedAt = Date()
        }
        return changed
    }

    var resolvedCustomChatCompletionsURL: String {
        get { customChatCompletionsURL ?? "" }
        set { customChatCompletionsURL = newValue }
    }

    var activeProjectID: UUID? {
        get {
            guard let activeProjectIDString else { return nil }
            return UUID(uuidString: activeProjectIDString)
        }
        set { activeProjectIDString = newValue?.uuidString }
    }

    @discardableResult
    func repairStaleModelSelection() -> Bool {
        let selectedProvider = provider
        let trimmedModel = modelID.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedModel.isEmpty else {
            modelID = selectedProvider.defaultModel
            updatedAt = Date()
            return true
        }

        if selectedProvider.modelOptions.contains(trimmedModel) {
            if trimmedModel != modelID { modelID = trimmedModel }
            return false
        }

        if selectedProvider == .local {
            modelID = selectedProvider.defaultModel
            updatedAt = Date()
            return true
        }

        if LocalModelCatalog.variant(for: trimmedModel) != nil {
            modelID = selectedProvider.defaultModel
            updatedAt = Date()
            return true
        }

        let belongsToAnotherBuiltInProvider = AIProvider.allCases.contains { candidate in
            candidate != selectedProvider && candidate.modelOptions.contains(trimmedModel)
        }
        if belongsToAnotherBuiltInProvider {
            modelID = selectedProvider.defaultModel
            updatedAt = Date()
            return true
        }

        // Unknown exact IDs are intentional: Settings exposes a manual model-ID
        // escape hatch for custom/new provider models before /models refresh knows
        // about them. Keep those instead of over-correcting.
        if trimmedModel != modelID {
            modelID = trimmedModel
            updatedAt = Date()
            return true
        }
        return false
    }

    init(
        provider: AIProvider = .local,
        modelID: String = AIProvider.local.defaultModel,
        customChatCompletionsURL: String = "",
        autoApproveWrites: Bool = false,
        activeWorkspaceName: String = "Default",
        activeProjectID: UUID? = nil,
        temperature: Double = 0.2,
        customSystemPrompt: String = ""
    ) {
        self.id = UUID()
        self.providerRawValue = provider.rawValue
        self.modelID = modelID
        self.customChatCompletionsURL = customChatCompletionsURL
        self.autoApproveWrites = autoApproveWrites
        self.activeWorkspaceName = activeWorkspaceName
        self.activeProjectIDString = activeProjectID?.uuidString
        self.temperature = temperature
        self.customSystemPrompt = customSystemPrompt.isEmpty ? nil : customSystemPrompt
        self.createdAt = Date()
        self.updatedAt = Date()
    }
}

enum FilesWorkspacePersistence {
    static func persistWorkspaceSelection(
        _ workspaceName: String,
        settings: AgentSettings?,
        now: Date = Date(),
        save: () throws -> Void
    ) throws {
        guard let settings else { return }

        let previousWorkspaceName = settings.activeWorkspaceName
        let previousUpdatedAt = settings.updatedAt
        settings.activeWorkspaceName = workspaceName
        settings.updatedAt = now

        do {
            try save()
        } catch {
            settings.activeWorkspaceName = previousWorkspaceName
            settings.updatedAt = previousUpdatedAt
            throw error
        }
    }

    static func persistProjectWorkspaceSelection(
        _ workspaceName: String,
        project: Project,
        settings: AgentSettings?,
        now: Date = Date(),
        save: () throws -> Void
    ) throws {
        let previousProjectWorkspaceName = project.workspaceName
        let previousSettings = settings.map(AgentSettingsPersistence.snapshot)

        project.workspaceName = workspaceName
        if let settings {
            settings.activeWorkspaceName = workspaceName
            settings.activeProjectID = project.id
            settings.updatedAt = now
        }

        do {
            try save()
        } catch {
            project.workspaceName = previousProjectWorkspaceName
            if let settings, let previousSettings {
                AgentSettingsPersistence.restore(previousSettings, to: settings)
            }
            throw error
        }
    }
}

enum AppRootPersistence {
    static func repairActiveWorkspaceName(
        _ workspaceName: String,
        settings: AgentSettings?,
        now: Date = Date(),
        save: () throws -> Void
    ) throws -> String {
        let safeName = SandboxWorkspace.sanitizedWorkspaceName(workspaceName)
        guard safeName != workspaceName else { return safeName }

        try FilesWorkspacePersistence.persistWorkspaceSelection(
            safeName,
            settings: settings,
            now: now,
            save: save
        )
        return safeName
    }

    static func persistActiveProjectSelection(
        _ project: Project,
        settings: AgentSettings?,
        now: Date = Date(),
        save: () throws -> Void
    ) throws -> String {
        let safeWorkspaceName = SandboxWorkspace.sanitizedWorkspaceName(project.workspaceName)
        let previousProjectWorkspaceName = project.workspaceName
        guard let settings else {
            project.workspaceName = safeWorkspaceName
            do {
                try save()
                return safeWorkspaceName
            } catch {
                project.workspaceName = previousProjectWorkspaceName
                throw error
            }
        }

        let previousSettings = AgentSettingsPersistence.snapshot(settings)
        project.workspaceName = safeWorkspaceName
        settings.activeProjectID = project.id
        settings.activeWorkspaceName = safeWorkspaceName
        settings.updatedAt = now

        do {
            try save()
            return safeWorkspaceName
        } catch {
            project.workspaceName = previousProjectWorkspaceName
            AgentSettingsPersistence.restore(previousSettings, to: settings)
            throw error
        }
    }

    @discardableResult
    static func repairStaleModelSelection(
        settings: AgentSettings?,
        now: Date = Date(),
        save: () throws -> Void
    ) throws -> Bool {
        guard let settings else { return false }

        let previous = AgentSettingsPersistence.snapshot(settings)
        let reportedChange = settings.repairStaleModelSelection()
        let repaired = AgentSettingsPersistence.snapshot(settings) != previous
        guard reportedChange || repaired else { return false }

        settings.updatedAt = now
        do {
            try save()
            return true
        } catch {
            AgentSettingsPersistence.restore(previous, to: settings)
            throw error
        }
    }
}

struct AppRootLaunchRepairResult {
    let settings: AgentSettings
    let project: Project
    let conversation: Conversation
    let createdSettings: Bool
    let createdConversation: Bool
}

enum AppRootLaunchRepair {
    static func ensureLaunchRecords(
        in context: ModelContext,
        settings suppliedSettings: AgentSettings?,
        selectedConversation: Conversation? = nil,
        now: Date = Date()
    ) throws -> AppRootLaunchRepairResult {
        let settings: AgentSettings
        let createdSettings: Bool
        if let suppliedSettings {
            settings = suppliedSettings
            createdSettings = false
        } else if let existing = try fetchSettings(in: context) {
            settings = existing
            createdSettings = false
        } else {
            let created = AgentSettings()
            context.insert(created)
            settings = created
            createdSettings = true
        }

        let project = ProjectBootstrap.ensureDefaultProject(in: context, settings: settings, now: now)
        let existingConversations = try fetchConversations(in: context)
        let launchCandidates = existingConversations.filter { conversation in
            guard let owner = conversation.project else { return true }
            return owner.id == project.id
        }
        let selectedLaunchConversation: Conversation? = {
            guard let selectedConversation else { return nil }
            guard let owner = selectedConversation.project else { return selectedConversation }
            return owner.id == project.id ? selectedConversation : nil
        }()
        let readyConversation = launchCandidates.first {
            $0.project == nil &&
            $0.title == LaunchConversationSelection.safeStartTitle &&
            !$0.hasUserMessages
        } ?? launchCandidates.first {
            $0.title == LaunchConversationSelection.safeStartTitle && !$0.hasUserMessages
        }
        let restorableConversation = launchCandidates.first(where: LaunchConversationSelection.isLaunchRestorable)

        let conversation: Conversation
        let createdConversation: Bool
        if let selectedLaunchConversation {
            conversation = selectedLaunchConversation
            createdConversation = false
        } else if let readyConversation {
            conversation = readyConversation
            createdConversation = false
        } else if let restorableConversation {
            conversation = restorableConversation
            createdConversation = false
        } else {
            let created = Conversation(title: LaunchConversationSelection.safeStartTitle, project: nil)
            context.insert(created)
            conversation = created
            createdConversation = true
            ProjectEventRecorder.record(
                project: nil,
                kind: .conversationStarted,
                title: "Launch conversation ready",
                detail: created.title,
                severity: .info,
                sourceType: .conversation,
                sourceID: created.id,
                context: context,
                now: now
            )
        }

        if conversation.title == LaunchConversationSelection.safeStartTitle, !conversation.hasUserMessages {
            conversation.project = nil
        }
        if settings.activeProjectID != project.id {
            settings.activeProjectID = project.id
            settings.updatedAt = now
        }
        let repairedWorkspaceName = repairedActiveWorkspaceName(project: project, settings: settings)
        if project.workspaceName != repairedWorkspaceName {
            project.workspaceName = repairedWorkspaceName
        }
        if settings.activeWorkspaceName != repairedWorkspaceName {
            settings.activeWorkspaceName = repairedWorkspaceName
            settings.updatedAt = now
        }

        return AppRootLaunchRepairResult(
            settings: settings,
            project: project,
            conversation: conversation,
            createdSettings: createdSettings,
            createdConversation: createdConversation
        )
    }

    private static func fetchSettings(in context: ModelContext) throws -> AgentSettings? {
        var descriptor = FetchDescriptor<AgentSettings>()
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    private static func fetchConversations(in context: ModelContext) throws -> [Conversation] {
        let descriptor = FetchDescriptor<Conversation>(
            sortBy: [SortDescriptor(\Conversation.updatedAt, order: .reverse)]
        )
        return try context.fetch(descriptor)
    }

    private static func repairedActiveWorkspaceName(project: Project, settings: AgentSettings) -> String {
        let projectWorkspace = project.workspaceName.trimmingCharacters(in: .whitespacesAndNewlines)
        let rawWorkspaceName = projectWorkspace.isEmpty ? settings.activeWorkspaceName : project.workspaceName
        return SandboxWorkspace.sanitizedWorkspaceName(rawWorkspaceName)
    }
}

enum AgentSettingsPersistence {
    struct Snapshot: Equatable {
        let providerRawValue: String?
        let modelID: String
        let customChatCompletionsURL: String?
        let autoApproveWrites: Bool
        let activeWorkspaceName: String
        let activeProjectIDString: String?
        let temperature: Double
        let customSystemPrompt: String?
        let updatedAt: Date
    }

    static func snapshot(_ settings: AgentSettings) -> Snapshot {
        Snapshot(
            providerRawValue: settings.providerRawValue,
            modelID: settings.modelID,
            customChatCompletionsURL: settings.customChatCompletionsURL,
            autoApproveWrites: settings.autoApproveWrites,
            activeWorkspaceName: settings.activeWorkspaceName,
            activeProjectIDString: settings.activeProjectIDString,
            temperature: settings.temperature,
            customSystemPrompt: settings.customSystemPrompt,
            updatedAt: settings.updatedAt
        )
    }

    static func restore(_ snapshot: Snapshot, to settings: AgentSettings) {
        settings.providerRawValue = snapshot.providerRawValue
        settings.modelID = snapshot.modelID
        settings.customChatCompletionsURL = snapshot.customChatCompletionsURL
        settings.autoApproveWrites = snapshot.autoApproveWrites
        settings.activeWorkspaceName = snapshot.activeWorkspaceName
        settings.activeProjectIDString = snapshot.activeProjectIDString
        settings.temperature = snapshot.temperature
        settings.customSystemPrompt = snapshot.customSystemPrompt
        settings.updatedAt = snapshot.updatedAt
    }

    static func materialExecutionChangeDetails(from previous: Snapshot, to current: Snapshot) -> [String] {
        var details: [String] = []

        if previous.providerRawValue != current.providerRawValue {
            details.append("Provider: \(providerDisplayName(previous.providerRawValue)) -> \(providerDisplayName(current.providerRawValue))")
        }

        if previous.modelID != current.modelID {
            details.append("Model: \(displayModel(previous.modelID)) -> \(displayModel(current.modelID))")
        }

        if previous.customChatCompletionsURL != current.customChatCompletionsURL {
            let oldEndpoint = endpointDisplayName(previous.customChatCompletionsURL)
            let newEndpoint = endpointDisplayName(current.customChatCompletionsURL)
            details.append("Endpoint: \(oldEndpoint) -> \(newEndpoint)")
        }

        if previous.autoApproveWrites != current.autoApproveWrites {
            details.append(current.autoApproveWrites ? "Writes: auto-approve enabled" : "Writes: approval required")
        }

        if abs(previous.temperature - current.temperature) >= 0.001 {
            details.append(String(format: "Temperature: %.1f -> %.1f", previous.temperature, current.temperature))
        }

        if normalizedPromptState(previous.customSystemPrompt) != normalizedPromptState(current.customSystemPrompt) {
            details.append("System prompt: \(normalizedPromptState(current.customSystemPrompt))")
        }

        return details
    }

    static func materialExecutionChangeDetail(from previous: Snapshot, to current: Snapshot) -> String? {
        let details = materialExecutionChangeDetails(from: previous, to: current)
        guard !details.isEmpty else { return nil }
        return details.joined(separator: "; ")
    }

    static func persist(
        settings: AgentSettings,
        now: Date = Date(),
        mutate: (AgentSettings) -> Void,
        save: () throws -> Void
    ) throws {
        let previous = snapshot(settings)
        mutate(settings)
        settings.updatedAt = now

        do {
            try save()
        } catch {
            restore(previous, to: settings)
            throw error
        }
    }

    private static func providerDisplayName(_ rawValue: String?) -> String {
        (AIProvider(rawValue: rawValue ?? "") ?? .openAI).displayName
    }

    private static func displayModel(_ modelID: String) -> String {
        let trimmed = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Default" : trimmed
    }

    private static func endpointDisplayName(_ endpoint: String?) -> String {
        let trimmed = endpoint?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return "default" }
        guard let url = URL(string: trimmed), let host = url.host, !host.isEmpty else {
            return "custom"
        }
        return host
    }

    private static func normalizedPromptState(_ prompt: String?) -> String {
        let trimmed = prompt?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "default" : "custom"
    }
}

enum ProjectBootstrap {
    static let defaultProjectName = "NovaForge Project"

    static func preferredProject(from projects: [Project], settings: AgentSettings?) -> Project? {
        if let activeProjectID = settings?.activeProjectID,
           let match = projects.first(where: { $0.id == activeProjectID }) {
            return match
        }
        if let defaultProject = projects.first(where: { $0.name == defaultProjectName }) {
            return defaultProject
        }
        return projects.sorted { lhs, rhs in
            if lhs.lastActivityAt != rhs.lastActivityAt {
                return lhs.lastActivityAt > rhs.lastActivityAt
            }
            return lhs.createdAt < rhs.createdAt
        }.first
    }

    @discardableResult
    static func ensureDefaultProject(
        in context: ModelContext,
        settings: AgentSettings?,
        now: Date = Date()
    ) -> Project {
        let projects = (try? context.fetch(FetchDescriptor<Project>())) ?? []
        let project: Project
        if let preferred = preferredProject(from: projects, settings: settings) {
            project = preferred
        } else {
            let workspaceName = settings?.activeWorkspaceName ?? "Default"
            let created = Project(name: defaultProjectName, workspaceName: workspaceName, now: now)
            context.insert(created)
            project = created
            ProjectEventRecorder.record(
                project: project,
                kind: .projectCreated,
                title: "Default project created",
                detail: "NovaForge created a durable project to own existing runs, files, terminal commands, and artifacts.",
                severity: .success,
                sourceType: .system,
                context: context,
                now: now
            )
        }

        var linkedCount = 0
        linkedCount += assignOrphanToolRuns(to: project, context: context)
        linkedCount += assignOrphanTerminalCommands(to: project, context: context)
        linkedCount += assignOrphanArtifacts(to: project, context: context)
        linkedCount += assignOrphanFileChanges(to: project, context: context)
        linkedCount += assignOrphanEvents(to: project, context: context)

        if linkedCount > 0 {
            ProjectEventRecorder.record(
                project: project,
                kind: .migrationLinked,
                title: "Existing work linked",
                detail: "\(linkedCount) existing records now belong to \(project.name).",
                severity: .info,
                sourceType: .system,
                context: context,
                now: now
            )
        }

        if settings?.activeProjectID != project.id {
            settings?.activeProjectID = project.id
            settings?.updatedAt = now
        }
        if project.workspaceName.isEmpty {
            project.workspaceName = settings?.activeWorkspaceName ?? "Default"
        }
        project.updatedAt = max(project.updatedAt, now)
        return project
    }

    private static func assignOrphanToolRuns(to project: Project, context: ModelContext) -> Int {
        let runs = (try? context.fetch(FetchDescriptor<ToolRun>())) ?? []
        var count = 0
        for run in runs where run.project == nil {
            run.project = project
            count += 1
        }
        return count
    }

    private static func assignOrphanTerminalCommands(to project: Project, context: ModelContext) -> Int {
        let commands = (try? context.fetch(FetchDescriptor<TerminalCommandRecord>())) ?? []
        var count = 0
        for command in commands where command.project == nil {
            command.project = project
            count += 1
        }
        return count
    }

    private static func assignOrphanArtifacts(to project: Project, context: ModelContext) -> Int {
        let artifacts = (try? context.fetch(FetchDescriptor<ProjectArtifact>())) ?? []
        var count = 0
        for artifact in artifacts where artifact.project == nil {
            artifact.project = project
            count += 1
        }
        return count
    }

    private static func assignOrphanFileChanges(to project: Project, context: ModelContext) -> Int {
        let changes = (try? context.fetch(FetchDescriptor<ProjectFileChange>())) ?? []
        var count = 0
        for change in changes where change.project == nil {
            change.project = project
            count += 1
        }
        return count
    }

    private static func assignOrphanEvents(to project: Project, context: ModelContext) -> Int {
        let events = (try? context.fetch(FetchDescriptor<ProjectEvent>())) ?? []
        var count = 0
        for event in events where event.project == nil {
            event.project = project
            count += 1
        }
        return count
    }
}

enum ProjectEventRecorder {
    @discardableResult
    static func record(
        project: Project?,
        kind: ProjectEventKind,
        title: String,
        detail: String = "",
        severity: ProjectEventSeverity = .info,
        sourceType: ProjectEventSourceType? = nil,
        sourceID: UUID? = nil,
        metadata: [String: String] = [:],
        context: ModelContext,
        now: Date = Date()
    ) -> ProjectEvent? {
        guard let project else { return nil }
        let metadataJSON = encodeMetadata(metadata)
        let event = ProjectEvent(
            project: project,
            kind: kind,
            title: title,
            detail: detail,
            severity: severity,
            sourceType: sourceType,
            sourceID: sourceID,
            metadataJSON: metadataJSON,
            createdAt: now
        )
        context.insert(event)
        update(project: project, with: event, now: now)
        ProjectOSRunLedger.apply(event: event, to: project, context: context, now: now)
        return event
    }

    @discardableResult
    static func recordMissionCheckpoint(
        project: Project?,
        trigger: String,
        sourceType: ProjectEventSourceType? = nil,
        sourceID: UUID? = nil,
        context: ModelContext,
        now: Date = Date()
    ) -> ProjectEvent? {
        guard let project else { return nil }
        let summary = ProjectMissionSummarizer.summarize(project: project, context: context)
        return recordMissionCheckpoint(
            project: project,
            contract: summary.missionContract,
            trigger: trigger,
            sourceType: sourceType,
            sourceID: sourceID,
            context: context,
            now: now
        )
    }

    @discardableResult
    static func recordMissionCheckpoint(
        project: Project?,
        contract: MissionOSContract,
        trigger: String,
        sourceType: ProjectEventSourceType? = nil,
        sourceID: UUID? = nil,
        context: ModelContext,
        now: Date = Date()
    ) -> ProjectEvent? {
        guard let project else { return nil }
        let checkpoint = MissionOSCheckpoint(contract: contract, trigger: trigger)
        return record(
            project: project,
            kind: .missionCheckpoint,
            title: "Mission OS checkpoint: \(contract.decisionLabel)",
            detail: contract.operatorDirective,
            severity: checkpoint.eventSeverity,
            sourceType: sourceType ?? .system,
            sourceID: sourceID,
            metadata: checkpoint.metadata,
            context: context,
            now: now
        )
    }

    @discardableResult
    static func ensureArtifact(
        _ artifact: WorkspaceArtifact,
        project: Project?,
        sourceToolRunID: UUID? = nil,
        context: ModelContext,
        now: Date = Date()
    ) -> ProjectArtifact? {
        guard let project else { return nil }
        let persisted = upsertArtifact(
            artifact,
            project: project,
            sourceToolRunID: sourceToolRunID,
            context: context,
            now: now
        )

        record(
            project: project,
            kind: .artifactCreated,
            title: artifact.isSwiftGameArtifact ? "Swift game artifact ready" : artifact.isWebPage ? "Web artifact ready" : "Artifact ready",
            detail: artifact.path,
            severity: .success,
            sourceType: .artifact,
            sourceID: persisted.id,
            metadata: ["path": artifact.path, "type": artifact.artifactType.rawValue],
            context: context,
            now: now
        )
        return persisted
    }

    @discardableResult
    static func noteArtifactPreview(
        _ artifact: WorkspaceArtifact,
        project: Project?,
        context: ModelContext,
        now: Date = Date()
    ) -> ProjectArtifact? {
        guard let project else { return nil }
        let persisted = upsertArtifact(
            artifact,
            project: project,
            sourceToolRunID: nil,
            context: context,
            now: now
        )
        record(
            project: project,
            kind: .artifactPreviewed,
            title: artifact.isSwiftGameArtifact ? "Swift game artifact previewed" : artifact.isWebPage ? "Web artifact previewed" : "Artifact previewed",
            detail: artifact.path,
            severity: .info,
            sourceType: .artifact,
            sourceID: persisted.id,
            metadata: ["path": artifact.path, "type": artifact.artifactType.rawValue],
            context: context,
            now: now
        )
        return persisted
    }

    @discardableResult
    static func recordFileChange(
        project: Project?,
        action: String,
        path: String,
        sourceToolRunID: UUID? = nil,
        sourceTerminalCommandID: UUID? = nil,
        context: ModelContext,
        now: Date = Date()
    ) -> ProjectFileChange? {
        guard let project else { return nil }
        let change = ProjectFileChange(
            project: project,
            action: action,
            path: path,
            sourceToolRunID: sourceToolRunID,
            sourceTerminalCommandID: sourceTerminalCommandID,
            createdAt: now
        )
        context.insert(change)

        let event = record(
            project: project,
            kind: .fileChanged,
            title: action,
            detail: path,
            severity: .success,
            sourceType: .workspace,
            sourceID: change.id,
            metadata: ["path": path, "action": action],
            context: context,
            now: now
        )
        change.sourceEventIDString = event?.id.uuidString
        return change
    }

    @discardableResult
    static func recordSettingsChange(
        project: Project?,
        detail: String,
        title: String = "Settings changed",
        context: ModelContext,
        now: Date = Date()
    ) -> ProjectEvent? {
        record(
            project: project,
            kind: .settingsChanged,
            title: title,
            detail: detail,
            severity: .info,
            sourceType: .settings,
            context: context,
            now: now
        )
    }

    private static func update(project: Project, with event: ProjectEvent, now: Date) {
        project.updatedAt = now
        project.lastActivityAt = now
        if event.kind == .missionCheckpoint {
            let metadata = event.metadata
            let directive = metadata["operatorDirective"] ?? event.detail
            let nextAction = metadata["nextAction"] ?? directive
            if event.severity == .running {
                project.status = .running
            } else if event.severity == .success, project.status == .running || project.status == .needsReview {
                project.status = .active
            }
            if event.severity == .success {
                project.blocker = ""
            }
            if !nextAction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                project.nextStep = nextAction
            }
            return
        }
        switch event.severity {
        case .failure:
            project.status = .needsReview
            project.blocker = event.title
            project.nextStep = "Review the failed event and retry or continue."
        case .warning:
            if project.status != .needsReview {
                project.status = .active
            }
            project.nextStep = event.title
        case .running:
            project.status = .running
            project.nextStep = event.title
        case .success:
            if project.status == .running || project.status == .needsReview {
                project.status = .active
            }
            if clearsBlocker(event) {
                project.blocker = ""
            }
            if event.kind == .runCompleted {
                project.nextStep = "Review the result or send the next request."
            } else if event.kind == .artifactCreated {
                project.nextStep = "Preview the latest artifact."
            } else if event.kind == .fileChanged {
                project.nextStep = "Verify the latest file change."
            } else if event.kind == .terminalCommand {
                project.nextStep = "Review the command output or run the next check."
            } else if event.kind == .agentProofCreated {
                project.nextStep = "Review the latest proof."
            }
        case .info:
            if project.nextStep.isEmpty {
                project.nextStep = event.title
            }
        }
    }

    private static func clearsBlocker(_ event: ProjectEvent) -> Bool {
        switch event.kind {
        case .runCompleted, .agentProofCreated, .artifactCreated, .fileChanged, .missionCheckpoint:
            return true
        default:
            return false
        }
    }

    private static func upsertArtifact(
        _ artifact: WorkspaceArtifact,
        project: Project,
        sourceToolRunID: UUID?,
        context: ModelContext,
        now: Date
    ) -> ProjectArtifact {
        if let existing = project.artifacts.first(where: { $0.path == artifact.path }) {
            existing.updatedAt = now
            existing.type = artifact.artifactType
            existing.kind = ProjectArtifact.kind(for: artifact.artifactType)
            existing.previewMode = artifact.previewMode
            existing.orientationPreference = artifact.orientationPreference
            if artifact.isSwiftGameArtifact {
                existing.status = .playable
                existing.exportStatus = .exported
                existing.aspectRatioValue = 16.0 / 9.0
            }
            if let sourceToolRunID {
                existing.sourceToolRunIDString = sourceToolRunID.uuidString
            }
            return existing
        }

        let persisted = ProjectArtifact(
            project: project,
            path: artifact.path,
            kind: ProjectArtifact.kind(for: artifact.artifactType),
            type: artifact.artifactType,
            description: artifact.isSwiftGameArtifact ? "Playable native Swift game artifact." : "",
            previewMode: artifact.previewMode,
            orientationPreference: artifact.orientationPreference,
            aspectRatio: artifact.isSwiftGameArtifact ? 16.0 / 9.0 : nil,
            status: artifact.isSwiftGameArtifact ? .playable : .generated,
            generatedFiles: [artifact.path],
            exportStatus: artifact.isSwiftGameArtifact ? .exported : .generated,
            sourceToolRunID: sourceToolRunID,
            now: now
        )
        context.insert(persisted)
        return persisted
    }

    private static func encodeMetadata(_ metadata: [String: String]) -> String? {
        guard !metadata.isEmpty,
              JSONSerialization.isValidJSONObject(metadata),
              let data = try? JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys, .withoutEscapingSlashes]) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }
}

enum ProjectMissionStatusKind: String, Equatable {
    case active
    case waiting
    case blocked
    case done

    var displayName: String {
        switch self {
        case .active: "Active"
        case .waiting: "Waiting"
        case .blocked: "Blocked"
        case .done: "Done"
        }
    }
}

enum ProjectCommandIntent: String, Codable, CaseIterable, Identifiable, Sendable {
    case continueMission
    case planNext
    case verifyWork
    case improveArtifact
    case fixBlocker
    case reviewEvidence

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .continueMission: "Continue Mission"
        case .planNext: "Plan Next"
        case .verifyWork: "Verify Work"
        case .improveArtifact: "Improve Artifact"
        case .fixBlocker: "Fix Blocker"
        case .reviewEvidence: "Review Evidence"
        }
    }

    var compactName: String {
        switch self {
        case .continueMission: "Continue"
        case .planNext: "Plan"
        case .verifyWork: "Verify"
        case .improveArtifact: "Artifact"
        case .fixBlocker: "Fix"
        case .reviewEvidence: "Review"
        }
    }

    var instructionFocus: String {
        switch self {
        case .continueMission:
            return "Choose and execute the highest-leverage next project step from the mission, current evidence, and workspace state."
        case .planNext:
            return "Inspect the project state and produce a concrete next-step plan before making changes unless an obvious low-risk action is available."
        case .verifyWork:
            return "Run appropriate checks, inspect recent changes, capture proof, and identify any remaining risk or blocker."
        case .improveArtifact:
            return "Inspect the latest artifact or project output, improve its usefulness and polish, then preview or validate it when possible."
        case .fixBlocker:
            return "Start from the blocker or failure evidence, reproduce or inspect it, patch the smallest useful fix, and verify the result."
        case .reviewEvidence:
            return "Review timeline, proof, artifacts, files, and runs; summarize what matters, then take the next safe action if it is clear."
        }
    }
}

struct ProjectOSPlannedStep: Identifiable, Equatable, Sendable {
    var id: String { key }
    var key: String
    var title: String
    var detail: String
    var reason: String
    var symbolName: String
    var startingStatus: ProjectOSStepStatus
}

enum ProjectOSPlanBuilder {
    static func makeSteps(
        project: Project,
        summary: ProjectMissionSummary,
        intent: ProjectCommandIntent,
        operatorNote: String
    ) -> [ProjectOSPlannedStep] {
        let note = operatorNote.trimmingCharacters(in: .whitespacesAndNewlines)
        let mission = summary.missionText.trimmingCharacters(in: .whitespacesAndNewlines)
        let nextStep = summary.nextStep.trimmingCharacters(in: .whitespacesAndNewlines)
        let proof = summary.missionContract.proofRequirement.trimmingCharacters(in: .whitespacesAndNewlines)
        let target = mission.isEmpty ? project.mission : mission
        let agentChoice = note.isEmpty ? (nextStep.isEmpty ? intent.instructionFocus : nextStep) : note

        var steps: [ProjectOSPlannedStep] = [
            ProjectOSPlannedStep(
                key: "context",
                title: "Read project context",
                detail: target.isEmpty ? "Load mission, files, timeline, runs, and proof." : target,
                reason: "ProjectOS grounds the run in project-owned state before it acts.",
                symbolName: "doc.text.magnifyingglass",
                startingStatus: .planning
            ),
            ProjectOSPlannedStep(
                key: "plan",
                title: "Create agent plan",
                detail: agentChoice,
                reason: "The plan should come from current evidence instead of a canned checklist.",
                symbolName: "list.bullet.clipboard.fill",
                startingStatus: .pending
            )
        ]

        switch intent {
        case .continueMission:
            steps.append(ProjectOSPlannedStep(
                key: "choose",
                title: "Choose next action",
                detail: nextStep.isEmpty ? "Pick the highest-leverage build step from evidence." : nextStep,
                reason: "The agent chooses the next step from mission, proof, blocker, and run history.",
                symbolName: "arrow.triangle.branch",
                startingStatus: .pending
            ))
            steps.append(ProjectOSPlannedStep(
                key: "execute",
                title: "Execute task",
                detail: "Edit, create, inspect, or run the concrete project action.",
                reason: "Visible work should map to tools, commands, files, or artifacts.",
                symbolName: "hammer.fill",
                startingStatus: .pending
            ))
        case .planNext:
            steps.append(ProjectOSPlannedStep(
                key: "draft-plan",
                title: "Draft task plan",
                detail: "Turn the mission into ordered next tasks, blockers, and proof checks.",
                reason: "ProjectOS needs an inspectable plan before deep work.",
                symbolName: "checklist",
                startingStatus: .pending
            ))
            steps.append(ProjectOSPlannedStep(
                key: "save-direction",
                title: "Save direction",
                detail: "Record the chosen next step so future runs know what to do.",
                reason: "The run should be resumable after relaunch.",
                symbolName: "tray.and.arrow.down.fill",
                startingStatus: .pending
            ))
        case .verifyWork:
            steps.append(ProjectOSPlannedStep(
                key: "verify",
                title: "Run verification",
                detail: proof.isEmpty ? "Use the fastest relevant build, test, screenshot, or smoke check." : proof,
                reason: "Completed work needs durable proof before review.",
                symbolName: "checkmark.shield.fill",
                startingStatus: .pending
            ))
            steps.append(ProjectOSPlannedStep(
                key: "risks",
                title: "Report risks",
                detail: "Name what passed, what changed, and what remains uncertain.",
                reason: "Proof should include remaining limitations.",
                symbolName: "exclamationmark.magnifyingglass",
                startingStatus: .pending
            ))
        case .improveArtifact:
            steps.append(ProjectOSPlannedStep(
                key: "inspect-artifact",
                title: "Inspect artifact",
                detail: summary.latestProofTitle.isEmpty ? "Find the latest project output or file to improve." : summary.latestProofTitle,
                reason: "Artifact work starts from the current proof surface.",
                symbolName: "shippingbox.fill",
                startingStatus: .pending
            ))
            steps.append(ProjectOSPlannedStep(
                key: "polish",
                title: "Polish output",
                detail: "Improve usefulness, clarity, and proof quality before handing it back.",
                reason: "The result should become easier to inspect or ship.",
                symbolName: "wand.and.stars",
                startingStatus: .pending
            ))
        case .fixBlocker:
            steps.append(ProjectOSPlannedStep(
                key: "inspect-blocker",
                title: "Inspect blocker",
                detail: summary.blocker.isEmpty ? "Find the failing run, error, or stuck approval." : summary.blocker,
                reason: "Recovery starts from the evidence that blocked the run.",
                symbolName: "exclamationmark.triangle.fill",
                startingStatus: .pending
            ))
            steps.append(ProjectOSPlannedStep(
                key: "repair",
                title: "Apply fix",
                detail: "Make the smallest useful repair and then verify it.",
                reason: "A blocker should produce a focused recovery path.",
                symbolName: "wrench.adjustable.fill",
                startingStatus: .pending
            ))
        case .reviewEvidence:
            steps.append(ProjectOSPlannedStep(
                key: "review-evidence",
                title: "Review evidence",
                detail: "Read timeline, runs, proof, artifacts, and file changes.",
                reason: "The next decision should be grounded in proof.",
                symbolName: "text.viewfinder",
                startingStatus: .pending
            ))
            steps.append(ProjectOSPlannedStep(
                key: "recommend",
                title: "Recommend action",
                detail: nextStep.isEmpty ? "Summarize what matters and choose the next safe move." : nextStep,
                reason: "ProjectOS should make the next action obvious.",
                symbolName: "lightbulb.fill",
                startingStatus: .pending
            ))
        }

        steps.append(ProjectOSPlannedStep(
            key: "proof",
            title: "Capture proof",
            detail: proof.isEmpty ? "Finish with checks, artifacts, files changed, and any remaining blocker." : proof,
            reason: "Every run should end with visible evidence or a named limitation.",
            symbolName: "checkmark.seal.fill",
            startingStatus: .pending
        ))
        return steps
    }
}

enum ProjectOSIntentDeriver {
    static func makeRunStartIntent(
        project: Project,
        summary: ProjectMissionSummary,
        intent: ProjectCommandIntent,
        operatorNote: String,
        now: Date
    ) -> ProjectOSIntentSnapshot {
        let note = operatorNote.trimmingCharacters(in: .whitespacesAndNewlines)
        let reason = note.isEmpty ? intent.instructionFocus : note
        return ProjectOSIntentSnapshot(
            mode: .readingContext,
            source: .runState,
            confidence: .observed,
            summary: "Reading project context for \(intent.displayName).",
            objectKind: .project,
            objectTitle: project.name,
            objectDetail: summary.missionText,
            filePath: "",
            command: "",
            toolName: "",
            testBuildGate: "",
            artifactPath: "",
            blocker: summary.blocker,
            proof: "",
            reason: reason,
            recommendedAction: summary.nextStep,
            timestamp: now
        )
    }

    static func makeIdleIntent(project: Project, now: Date = Date()) -> ProjectOSIntentSnapshot {
        ProjectOSIntentSnapshot.idle(project: project, now: now)
    }

    static func makeRecoveryIntent(run: ProjectOSRun, now: Date) -> ProjectOSIntentSnapshot {
        ProjectOSIntentSnapshot(
            mode: .stoppedResumable,
            source: .recovery,
            confidence: .observed,
            summary: "Stopped after relaunch; the run can be resumed from ProjectOS.",
            objectKind: .step,
            objectTitle: run.currentAction.isEmpty ? "Recovered ProjectOS run" : run.currentAction,
            objectDetail: run.resumeState,
            filePath: "",
            command: run.currentCommand,
            toolName: "",
            testBuildGate: "",
            artifactPath: run.artifactsSummary,
            blocker: run.blockerReason,
            proof: run.proofSummary,
            reason: run.resumeState.isEmpty ? "The app relaunched before the ProjectOS run completed." : run.resumeState,
            recommendedAction: run.nextStep.isEmpty ? "Resume the project run when ready." : run.nextStep,
            timestamp: now
        )
    }

    static func makeIntent(
        for event: ProjectEvent,
        run: ProjectOSRun,
        project: Project,
        activeStep: ProjectOSStep?,
        now: Date
    ) -> ProjectOSIntentSnapshot {
        let metadata = mergedMetadata(for: event)
        let activeTitle = activeStep?.title.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let eventDetail = clean(event.detail)
        let fallbackObject = activeTitle.isEmpty ? run.currentAction : activeTitle

        switch event.kind {
        case .conversationContinued, .autoContinueStarted:
            return snapshot(
                mode: .readingContext,
                source: .projectEvent,
                confidence: .observed,
                summary: event.title.isEmpty ? "Project run started." : event.title,
                objectKind: .project,
                objectTitle: project.name,
                objectDetail: project.mission,
                reason: eventDetail.isEmpty ? "ProjectOS is loading project-owned mission, history, files, and proof." : eventDetail,
                recommendedAction: run.nextStep.isEmpty ? project.nextStep : run.nextStep,
                now: now
            )
        case .promptQueued:
            return snapshot(
                mode: .planning,
                source: .projectEvent,
                confidence: .observed,
                summary: event.title.isEmpty ? "Prompt queued for ProjectOS." : event.title,
                objectKind: .project,
                objectTitle: project.name,
                objectDetail: eventDetail,
                reason: "ProjectOS queued the run behind the project surface.",
                recommendedAction: run.nextStep.isEmpty ? project.nextStep : run.nextStep,
                now: now
            )
        case .responseSaved where event.severity == .running:
            return snapshot(
                mode: .planning,
                source: .runtimeTrace,
                confidence: .inferred,
                summary: event.title.isEmpty ? "Saving the agent plan." : event.title,
                objectKind: .step,
                objectTitle: fallbackObject.isEmpty ? "Create agent plan" : fallbackObject,
                objectDetail: eventDetail,
                reason: "The runtime saved planning text before tool execution.",
                recommendedAction: run.nextStep,
                now: now
            )
        case .agentPlanCreated:
            return snapshot(
                mode: .planning,
                source: .projectEvent,
                confidence: .observed,
                summary: event.title.isEmpty ? "Agent plan prepared." : event.title,
                objectKind: .step,
                objectTitle: activeTitle.isEmpty ? "Create agent plan" : activeTitle,
                objectDetail: eventDetail,
                reason: eventDetail.isEmpty ? "The agent produced a structured plan from current project evidence." : eventDetail,
                recommendedAction: run.nextStep,
                now: now
            )
        case .toolQueued:
            let tool = metadata["tool"] ?? eventDetail
            return snapshot(
                mode: toolLooksLikeRead(tool) ? .inspectingFiles : .runningTool,
                source: .projectEvent,
                confidence: .observed,
                summary: event.title.isEmpty ? "Tool queued." : event.title,
                objectKind: .tool,
                objectTitle: tool.isEmpty ? "Tool" : tool,
                objectDetail: eventDetail,
                toolName: tool,
                reason: "The runtime selected a concrete tool for the active ProjectOS step.",
                recommendedAction: run.nextStep,
                now: now
            )
        case .toolApprovalRequested:
            let tool = metadata["tool"] ?? metadata["name"] ?? toolName(from: event.title)
            let path = metadata["path"] ?? metadata["file"] ?? pathFromMetadata(metadata)
            return snapshot(
                mode: .waitingApproval,
                source: .toolApproval,
                confidence: .observed,
                summary: event.title.isEmpty ? "Approval needed." : event.title,
                objectKind: .approval,
                objectTitle: tool.isEmpty ? "Approval required" : tool,
                objectDetail: eventDetail,
                filePath: path,
                toolName: tool,
                blocker: eventDetail,
                reason: eventDetail.isEmpty ? "A mutating tool must be reviewed before it can continue." : eventDetail,
                recommendedAction: "Approve or reject the pending tool.",
                now: now
            )
        case .toolApproved:
            let tool = metadata["tool"] ?? metadata["name"] ?? toolName(from: event.title)
            return snapshot(
                mode: .runningTool,
                source: .toolApproval,
                confidence: .observed,
                summary: event.title.isEmpty ? "Approval resolved." : event.title,
                objectKind: .tool,
                objectTitle: tool.isEmpty ? "Approved tool" : tool,
                objectDetail: eventDetail,
                toolName: tool,
                reason: "The approved tool is now running from the ProjectOS approval gate.",
                recommendedAction: run.nextStep,
                now: now
            )
        case .toolRejected:
            return snapshot(
                mode: .stoppedResumable,
                source: .toolApproval,
                confidence: .observed,
                summary: event.title.isEmpty ? "Tool rejected." : event.title,
                objectKind: .approval,
                objectTitle: toolName(from: event.title),
                objectDetail: eventDetail,
                blocker: eventDetail,
                reason: "The user rejected the pending tool before it changed the workspace.",
                recommendedAction: "Review the rejected action or rerun with a safer path.",
                now: now
            )
        case .toolCompleted:
            let tool = metadata["tool"] ?? metadata["name"] ?? toolName(from: event.title)
            return snapshot(
                mode: .runningTool,
                source: .projectEvent,
                confidence: .observed,
                summary: event.title.isEmpty ? "Tool completed." : event.title,
                objectKind: .tool,
                objectTitle: tool.isEmpty ? "Completed tool" : tool,
                objectDetail: eventDetail,
                toolName: tool,
                reason: "A tool finished and ProjectOS is choosing the next visible step.",
                recommendedAction: run.nextStep,
                now: now
            )
        case .terminalCommand:
            let command = metadata["command"] ?? eventDetail
            let mode = commandIntentMode(command)
            return snapshot(
                mode: event.severity == .failure ? .blocked : mode,
                source: .terminalCommand,
                confidence: .observed,
                summary: event.title.isEmpty ? "Terminal command recorded." : event.title,
                objectKind: mode == .runningTests || mode == .verifyingOutput || mode == .capturingScreenshot ? .testBuildGate : .command,
                objectTitle: commandTitle(command),
                objectDetail: command,
                command: command,
                testBuildGate: mode == .runningTests || mode == .verifyingOutput || mode == .capturingScreenshot ? command : "",
                blocker: event.severity == .failure ? eventDetail : "",
                reason: commandReason(command, mode: mode, failed: event.severity == .failure),
                recommendedAction: event.severity == .failure ? "Inspect the failed command output and retry." : run.nextStep,
                now: now
            )
        case .fileChanged:
            let path = metadata["path"] ?? eventDetail
            return snapshot(
                mode: .editingCode,
                source: .fileChange,
                confidence: .observed,
                summary: event.title.isEmpty ? "File changed." : event.title,
                objectKind: .file,
                objectTitle: filename(path),
                objectDetail: path,
                filePath: path,
                reason: "A project-owned file change was recorded in the ledger.",
                recommendedAction: "Verify the latest file change.",
                now: now
            )
        case .artifactCreated, .artifactPreviewed:
            let path = metadata["path"] ?? eventDetail
            return snapshot(
                mode: .producingProof,
                source: .artifact,
                confidence: .observed,
                summary: event.title.isEmpty ? "Artifact ready." : event.title,
                objectKind: .artifact,
                objectTitle: filename(path),
                objectDetail: path,
                artifactPath: path,
                proof: path,
                reason: event.kind == .artifactPreviewed ? "The user opened a project artifact for inspection." : "A project artifact became available as proof.",
                recommendedAction: event.kind == .artifactPreviewed ? run.nextStep : "Preview the latest artifact.",
                now: now
            )
        case .agentProofCreated:
            let failed = event.severity == .failure
            return snapshot(
                mode: failed ? .blocked : .completedProof,
                source: .proof,
                confidence: .observed,
                summary: event.title.isEmpty ? "Agent proof captured." : event.title,
                objectKind: failed ? .blocker : .proof,
                objectTitle: failed ? "Proof failed" : "Agent proof",
                objectDetail: eventDetail,
                blocker: failed ? eventDetail : "",
                proof: failed ? "" : eventDetail,
                reason: failed ? "The proof event recorded a failure." : "The run closed with visible ProjectOS proof.",
                recommendedAction: failed ? "Fix the failed proof path." : project.nextStep,
                now: now
            )
        case .runCompleted:
            return snapshot(
                mode: .summarizingCompletion,
                source: .runState,
                confidence: .observed,
                summary: event.title.isEmpty ? "Run completed." : event.title,
                objectKind: .proof,
                objectTitle: "Completion summary",
                objectDetail: eventDetail,
                proof: eventDetail,
                reason: "The runtime reported a completed ProjectOS run.",
                recommendedAction: project.nextStep,
                now: now
            )
        case .runFailed, .toolFailed:
            return snapshot(
                mode: .blocked,
                source: .runState,
                confidence: .observed,
                summary: event.title.isEmpty ? "Run failed." : event.title,
                objectKind: .blocker,
                objectTitle: event.title.isEmpty ? "Failed evidence" : event.title,
                objectDetail: eventDetail,
                blocker: eventDetail,
                reason: eventDetail.isEmpty ? "The latest runtime event failed." : eventDetail,
                recommendedAction: "Review the failed evidence and retry.",
                now: now
            )
        case .runPaused:
            return snapshot(
                mode: .stoppedResumable,
                source: .runState,
                confidence: .observed,
                summary: event.title.isEmpty ? "Run stopped." : event.title,
                objectKind: .step,
                objectTitle: fallbackObject.isEmpty ? "Stopped ProjectOS run" : fallbackObject,
                objectDetail: eventDetail,
                reason: eventDetail.isEmpty ? "The run paused before completion." : eventDetail,
                recommendedAction: "Resume or retry the project run.",
                now: now
            )
        case .missionCheckpoint:
            return checkpointIntent(event: event, run: run, project: project, activeStep: activeStep, metadata: metadata, now: now)
        default:
            return snapshot(
                mode: run.status.isTerminal ? .summarizingCompletion : .runningTool,
                source: .projectEvent,
                confidence: .inferred,
                summary: event.title.isEmpty ? "Project event recorded." : event.title,
                objectKind: .step,
                objectTitle: fallbackObject.isEmpty ? run.status.displayName : fallbackObject,
                objectDetail: eventDetail,
                reason: eventDetail,
                recommendedAction: run.nextStep.isEmpty ? project.nextStep : run.nextStep,
                now: now
            )
        }
    }

    private static func checkpointIntent(
        event: ProjectEvent,
        run: ProjectOSRun,
        project: Project,
        activeStep: ProjectOSStep?,
        metadata: [String: String],
        now: Date
    ) -> ProjectOSIntentSnapshot {
        let phase = metadata["phase"]?.lowercased() ?? ""
        let mode: ProjectOSIntentMode = {
            if event.severity == .failure { return .blocked }
            if event.severity == .warning { return .waitingApproval }
            if phase.contains("plan") { return .planning }
            if phase.contains("verify") { return .verifyingOutput }
            if phase.contains("proof") { return .producingProof }
            if phase.contains("decide") { return .summarizingCompletion }
            return run.status == .planning ? .planning : .readingContext
        }()
        let activeTitle = activeStep?.title.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return snapshot(
            mode: mode,
            source: .projectEvent,
            confidence: .inferred,
            summary: event.title.isEmpty ? "Mission checkpoint." : event.title,
            objectKind: .step,
            objectTitle: activeTitle.isEmpty ? (metadata["decisionLabel"] ?? mode.displayName) : activeTitle,
            objectDetail: clean(event.detail),
            blocker: event.severity == .failure ? clean(event.detail) : "",
            reason: metadata["operatorDirective"] ?? clean(event.detail),
            recommendedAction: metadata["nextAction"] ?? (run.nextStep.isEmpty ? project.nextStep : run.nextStep),
            now: now
        )
    }

    private static func snapshot(
        mode: ProjectOSIntentMode,
        source: ProjectOSIntentSource,
        confidence: ProjectOSIntentConfidence,
        summary: String,
        objectKind: ProjectOSWorkObjectKind,
        objectTitle: String,
        objectDetail: String,
        filePath: String = "",
        command: String = "",
        toolName: String = "",
        testBuildGate: String = "",
        artifactPath: String = "",
        blocker: String = "",
        proof: String = "",
        reason: String,
        recommendedAction: String,
        now: Date
    ) -> ProjectOSIntentSnapshot {
        ProjectOSIntentSnapshot(
            mode: mode,
            source: source,
            confidence: confidence,
            summary: summary,
            objectKind: objectKind,
            objectTitle: objectTitle,
            objectDetail: objectDetail,
            filePath: filePath,
            command: command,
            toolName: toolName,
            testBuildGate: testBuildGate,
            artifactPath: artifactPath,
            blocker: blocker,
            proof: proof,
            reason: reason,
            recommendedAction: recommendedAction,
            timestamp: now
        )
    }

    private static func mergedMetadata(for event: ProjectEvent) -> [String: String] {
        var metadata = event.metadata
        if let detailMetadata = decodeDictionary(event.detail) {
            for (key, value) in detailMetadata where metadata[key] == nil {
                metadata[key] = value
            }
        }
        return metadata
    }

    private static func decodeDictionary(_ value: String) -> [String: String]? {
        guard let data = value.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any] else {
            return nil
        }
        return dictionary.reduce(into: [:]) { result, pair in
            result[pair.key] = "\(pair.value)"
        }
    }

    private static func pathFromMetadata(_ metadata: [String: String]) -> String {
        metadata["path"] ?? metadata["filePath"] ?? metadata["target"] ?? ""
    }

    private static func clean(_ text: String) -> String {
        text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func filename(_ path: String) -> String {
        let name = URL(fileURLWithPath: path).lastPathComponent
        return name.isEmpty ? path : name
    }

    private static func toolName(from title: String) -> String {
        let pieces = title.split(separator: " ")
        return pieces.last.map(String.init) ?? title
    }

    private static func toolLooksLikeRead(_ tool: String) -> Bool {
        let lower = tool.lowercased()
        return lower.contains("read") || lower.contains("list") || lower.contains("search") || lower.contains("inspect")
    }

    private static func commandIntentMode(_ command: String) -> ProjectOSIntentMode {
        let lower = command.lowercased()
        if lower.contains("screenshot") || lower.contains("simctl io") {
            return .capturingScreenshot
        }
        if lower.contains("test") || lower.contains("xcodebuild") || lower.contains("build") {
            return .runningTests
        }
        if lower.contains("validate") || lower.contains("check") || lower.contains("smoke") || lower.contains("tour") || lower.contains("proof") {
            return .verifyingOutput
        }
        return .runningCommand
    }

    private static func commandTitle(_ command: String) -> String {
        let trimmed = clean(command)
        guard !trimmed.isEmpty else { return "Command" }
        let first = trimmed.split(separator: " ").prefix(2).joined(separator: " ")
        return first.isEmpty ? trimmed : first
    }

    private static func commandReason(_ command: String, mode: ProjectOSIntentMode, failed: Bool) -> String {
        if failed { return "The command failed and now blocks the ProjectOS run." }
        switch mode {
        case .runningTests:
            return "A build or test command is checking the current work."
        case .verifyingOutput:
            return "A verification command is producing durable evidence."
        case .capturingScreenshot:
            return "A screenshot command is capturing visual proof."
        default:
            return "A terminal command is running or has just completed for the active step."
        }
    }
}

enum ProjectOSRunLedger {
    @discardableResult
    static func startRun(
        project: Project,
        summary: ProjectMissionSummary,
        intent: ProjectCommandIntent,
        operatorNote: String,
        sourceConversationID: UUID?,
        origin: ProjectOSRunOrigin,
        context: ModelContext,
        now: Date = Date()
    ) -> ProjectOSRun {
        let run = ProjectOSRun(
            project: project,
            projectName: project.name,
            mission: summary.missionText,
            status: .planning,
            origin: origin,
            sourceConversationID: sourceConversationID,
            now: now
        )
        run.currentAction = "Reading project context"
        run.currentCommand = intent.displayName
        run.nextStep = summary.nextStep
        run.latestEventTitle = "ProjectOS run started"
        run.latestEventDetail = intent.instructionFocus
        context.insert(run)
        if !project.projectOSRuns.contains(where: { $0.id == run.id }) {
            project.projectOSRuns.append(run)
        }

        let plannedSteps = ProjectOSPlanBuilder.makeSteps(
            project: project,
            summary: summary,
            intent: intent,
            operatorNote: operatorNote
        )
        for (index, plannedStep) in plannedSteps.enumerated() {
            let step = ProjectOSStep(
                run: run,
                key: plannedStep.key,
                orderIndex: index,
                title: plannedStep.title,
                detail: plannedStep.detail,
                reason: plannedStep.reason,
                status: plannedStep.startingStatus,
                command: index == 0 ? intent.displayName : "",
                now: now
            )
            context.insert(step)
            run.steps.append(step)
        }
        run.currentAction = sortedSteps(for: run).first?.title ?? run.currentAction
        run.nextStep = sortedSteps(for: run).dropFirst().first?.title ?? summary.nextStep
        run.applyIntent(ProjectOSIntentDeriver.makeRunStartIntent(
            project: project,
            summary: summary,
            intent: intent,
            operatorNote: operatorNote,
            now: now
        ))
        return run
    }

    static func apply(
        event: ProjectEvent,
        to project: Project,
        context: ModelContext,
        now: Date = Date()
    ) {
        guard shouldApply(event) else { return }
        guard let run = runForEvent(event, project: project, context: context, now: now) else { return }

        run.projectName = project.name
        run.mission = project.mission
        run.latestEventTitle = event.title
        run.latestEventDetail = event.detail
        run.progressEventCount += 1
        run.updatedAt = now

        switch event.kind {
        case .conversationContinued, .autoContinueStarted:
            run.status = .planning
            run.planningState = "Starting project run"
            run.currentAction = event.title.isEmpty ? "Starting project run" : event.title
            run.nextStep = event.detail.isEmpty ? project.nextStep : event.detail
            markStep(run, keys: ["context"], status: .planning, result: event.detail, now: now)
        case .promptQueued where event.severity == .running:
            run.status = .planning
            run.planningState = "Prompt queued behind ProjectOS"
            run.currentAction = "Preparing project run"
        case .agentPlanCreated:
            run.status = .running
            run.planningState = "Agent-authored plan recorded"
            run.currentAction = event.title.isEmpty ? "Agent plan created" : event.title
            run.nextStep = nextOpenStep(after: "plan", in: run)?.title ?? project.nextStep
            markStep(run, keys: ["context", "plan", "draft-plan"], status: .completed, result: event.detail, now: now)
            markNextOpenStepRunning(run, detail: event.detail, now: now)
        case .missionCheckpoint:
            applyMissionCheckpoint(event, to: run, project: project, now: now)
        case .responseSaved where event.severity == .running:
            run.status = .planning
            run.currentAction = event.title.isEmpty ? "Saving agent plan" : event.title
            markStep(run, keys: ["plan"], status: .planning, result: event.detail, now: now)
        case .toolQueued:
            run.status = .running
            run.currentAction = event.title.isEmpty ? "Tool queued" : event.title
            run.currentCommand = event.detail
            markNextOpenStepRunning(run, detail: event.detail, now: now)
        case .toolApprovalRequested:
            run.status = .waiting
            run.waitingReason = event.detail.isEmpty ? event.title : event.detail
            run.currentAction = event.title.isEmpty ? "Waiting for approval" : event.title
            run.currentCommand = event.detail
            markActiveStep(run, status: .waiting, result: run.waitingReason, now: now)
        case .toolApproved:
            run.status = .running
            run.waitingReason = ""
            run.currentAction = event.title.isEmpty ? "Approval resolved" : event.title
            markActiveStep(run, status: .running, result: event.detail, now: now)
        case .toolRejected:
            run.status = .stopped
            run.resumeState = "Rejected approval can be retried after review."
            run.completedAt = now
            run.currentAction = event.title.isEmpty ? "Tool rejected" : event.title
            markActiveStep(run, status: .stopped, result: event.detail, now: now)
        case .toolCompleted:
            run.status = .running
            run.currentAction = event.title.isEmpty ? "Tool completed" : event.title
            run.currentCommand = event.detail
            markStep(run, keys: ["execute", "repair", "polish"], status: .completed, result: event.detail, now: now)
            markNextOpenStepRunning(run, detail: event.detail, now: now)
        case .terminalCommand:
            run.currentCommand = event.metadata["command"] ?? event.detail
            if event.severity == .failure {
                fail(run, reason: event.detail.isEmpty ? event.title : event.detail, now: now)
            } else {
                run.status = .running
                run.currentAction = event.title.isEmpty ? "Command completed" : event.title
                let command = run.currentCommand.lowercased()
                let keys = command.contains("test") || command.contains("build") || command.contains("validate") || command.contains("screenshot") || command.contains("smoke")
                    ? ["verify", "risks"]
                    : ["execute", "review-evidence"]
                markStep(run, keys: keys, status: .completed, result: event.detail, command: run.currentCommand, now: now)
                markNextOpenStepRunning(run, detail: event.detail, now: now)
            }
        case .fileChanged:
            run.status = .running
            run.changedFilesSummary = event.detail.isEmpty ? event.title : event.detail
            run.currentAction = event.title.isEmpty ? "File changed" : event.title
            markStep(run, keys: ["execute", "repair", "polish", "save-direction"], status: .completed, result: event.detail, now: now)
            markNextOpenStepRunning(run, detail: event.detail, now: now)
        case .artifactCreated, .artifactPreviewed:
            run.status = .running
            run.artifactsSummary = event.detail.isEmpty ? event.title : event.detail
            run.currentAction = event.title.isEmpty ? "Artifact ready" : event.title
            markStep(run, keys: ["proof", "inspect-artifact"], status: event.kind == .artifactCreated ? .completed : .running, result: event.detail, now: now)
        case .agentProofCreated:
            if event.severity == .failure {
                run.proofSummary = event.detail
                fail(run, reason: event.detail.isEmpty ? event.title : event.detail, now: now)
            } else {
                run.status = .completed
                run.proofSummary = event.detail.isEmpty ? event.title : event.detail
                run.currentAction = "Proof captured"
                run.nextStep = project.nextStep
                run.completedAt = now
                completeOpenSteps(run, result: run.proofSummary, now: now)
            }
        case .runCompleted:
            run.status = .completed
            run.proofSummary = run.proofSummary.isEmpty ? (event.detail.isEmpty ? event.title : event.detail) : run.proofSummary
            run.currentAction = "Run complete"
            run.nextStep = project.nextStep
            run.completedAt = now
            completeOpenSteps(run, result: run.proofSummary, now: now)
        case .runFailed, .toolFailed:
            fail(run, reason: event.detail.isEmpty ? event.title : event.detail, now: now)
        case .runPaused:
            run.status = .stopped
            run.resumeState = event.detail.isEmpty ? "Stopped before completion." : event.detail
            run.currentAction = event.title.isEmpty ? "Run stopped" : event.title
            run.completedAt = now
            markActiveStep(run, status: .stopped, result: run.resumeState, now: now)
        default:
            break
        }

        run.applyIntent(ProjectOSIntentDeriver.makeIntent(
            for: event,
            run: run,
            project: project,
            activeStep: activeStep(for: run),
            now: now
        ))
    }

    private static func shouldApply(_ event: ProjectEvent) -> Bool {
        switch event.kind {
        case .conversationContinued, .promptQueued, .agentPlanCreated, .agentProofCreated, .missionCheckpoint,
             .responseSaved, .toolQueued, .toolApprovalRequested, .toolApproved, .toolRejected,
             .toolCompleted, .toolFailed, .runCompleted, .runFailed, .runPaused, .artifactCreated,
             .artifactPreviewed, .fileChanged, .terminalCommand, .autoContinueStarted:
            return true
        default:
            return false
        }
    }

    private static func runForEvent(
        _ event: ProjectEvent,
        project: Project,
        context: ModelContext,
        now: Date
    ) -> ProjectOSRun? {
        let runs = project.projectOSRuns.sorted { lhs, rhs in
            if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
            return lhs.createdAt > rhs.createdAt
        }
        if let sourceID = event.sourceIDString,
           event.sourceType == .conversation,
           let matching = runs.first(where: { $0.sourceConversationIDString == sourceID && !$0.status.isTerminal }) {
            return matching
        }
        if let open = runs.first(where: { !$0.status.isTerminal }) {
            return open
        }
        guard shouldSynthesizeRun(for: event) else { return nil }
        return synthesizeRun(for: event, project: project, context: context, now: now)
    }

    private static func shouldSynthesizeRun(for event: ProjectEvent) -> Bool {
        switch event.kind {
        case .agentPlanCreated, .toolApprovalRequested, .runCompleted, .runFailed, .runPaused, .autoContinueStarted:
            return true
        case .promptQueued:
            return event.severity == .running
        default:
            return false
        }
    }

    private static func synthesizeRun(
        for event: ProjectEvent,
        project: Project,
        context: ModelContext,
        now: Date
    ) -> ProjectOSRun {
        let sourceConversationID = event.sourceType == .conversation ? event.sourceIDString.flatMap { UUID(uuidString: $0) } : nil
        let run = ProjectOSRun(
            project: project,
            projectName: project.name,
            mission: project.mission,
            status: .planning,
            origin: .recovered,
            sourceConversationID: sourceConversationID,
            now: now
        )
        context.insert(run)
        if !project.projectOSRuns.contains(where: { $0.id == run.id }) {
            project.projectOSRuns.append(run)
        }
        let steps = [
            ProjectOSPlannedStep(key: "context", title: "Read project context", detail: project.mission, reason: "Recovered from persisted project events.", symbolName: "doc.text.magnifyingglass", startingStatus: .completed),
            ProjectOSPlannedStep(key: "plan", title: "Create agent plan", detail: event.detail, reason: "Recovered from the event ledger.", symbolName: "list.bullet.clipboard.fill", startingStatus: .planning),
            ProjectOSPlannedStep(key: "execute", title: "Execute visible work", detail: "Tools, files, commands, or artifacts advance this step.", reason: "Runtime events supply the proof trail.", symbolName: "hammer.fill", startingStatus: .pending),
            ProjectOSPlannedStep(key: "verify", title: "Verify work", detail: "Run a check, build, test, screenshot, or proof review.", reason: "Verification keeps ProjectOS honest.", symbolName: "checkmark.shield.fill", startingStatus: .pending),
            ProjectOSPlannedStep(key: "proof", title: "Capture proof", detail: "Summarize results, files, artifacts, commands, and limitations.", reason: "ProjectOS completes with proof.", symbolName: "checkmark.seal.fill", startingStatus: .pending)
        ]
        for (index, planned) in steps.enumerated() {
            let step = ProjectOSStep(
                run: run,
                key: planned.key,
                orderIndex: index,
                title: planned.title,
                detail: planned.detail,
                reason: planned.reason,
                status: planned.startingStatus,
                now: now
            )
            context.insert(step)
            run.steps.append(step)
        }
        return run
    }

    private static func applyMissionCheckpoint(
        _ event: ProjectEvent,
        to run: ProjectOSRun,
        project: Project,
        now: Date
    ) {
        let metadata = event.metadata
        let nextAction = metadata["nextAction"] ?? project.nextStep
        run.currentAction = event.title.isEmpty ? "Mission checkpoint" : event.title
        run.nextStep = nextAction
        if let phase = metadata["phase"] {
            run.planningState = phase.capitalized
        }
        switch event.severity {
        case .failure:
            fail(run, reason: event.detail.isEmpty ? event.title : event.detail, now: now)
        case .warning:
            run.status = .waiting
            run.waitingReason = event.detail
            markActiveStep(run, status: .waiting, result: event.detail, now: now)
        case .running:
            run.status = .running
            markNextOpenStepRunning(run, detail: event.detail, now: now)
        case .success, .info:
            if !run.status.isTerminal {
                run.status = .running
            }
        }
    }

    private static func fail(_ run: ProjectOSRun, reason: String, now: Date) {
        run.status = .failed
        run.failureReason = reason
        run.blockerReason = reason
        run.currentAction = "Blocked by failed evidence"
        run.completedAt = now
        markActiveStep(run, status: .failed, result: reason, now: now)
    }

    private static func sortedSteps(for run: ProjectOSRun) -> [ProjectOSStep] {
        run.steps.sorted { lhs, rhs in
            if lhs.orderIndex != rhs.orderIndex { return lhs.orderIndex < rhs.orderIndex }
            return lhs.createdAt < rhs.createdAt
        }
    }

    private static func activeStep(for run: ProjectOSRun) -> ProjectOSStep? {
        sortedSteps(for: run).first {
            $0.status == .running || $0.status == .planning || $0.status == .waiting || $0.status == .blocked
        } ?? sortedSteps(for: run).first { !$0.status.isTerminal } ?? sortedSteps(for: run).last
    }

    private static func nextOpenStep(after key: String, in run: ProjectOSRun) -> ProjectOSStep? {
        let steps = sortedSteps(for: run)
        guard let index = steps.firstIndex(where: { $0.key == key }) else {
            return steps.first(where: { !$0.status.isTerminal })
        }
        return steps.dropFirst(index + 1).first { !$0.status.isTerminal }
    }

    private static func markNextOpenStepRunning(_ run: ProjectOSRun, detail: String, now: Date) {
        guard let step = sortedSteps(for: run).first(where: { !$0.status.isTerminal }) else { return }
        mark(step, status: .running, result: detail, now: now)
        run.currentAction = step.title
        run.nextStep = nextOpenStep(after: step.key, in: run)?.title ?? run.nextStep
    }

    private static func markActiveStep(_ run: ProjectOSRun, status: ProjectOSStepStatus, result: String, now: Date) {
        let active = sortedSteps(for: run).first { $0.status == .running || $0.status == .planning || $0.status == .waiting } ??
            sortedSteps(for: run).first { !$0.status.isTerminal }
        guard let active else { return }
        mark(active, status: status, result: result, now: now)
    }

    private static func markStep(
        _ run: ProjectOSRun,
        keys: [String],
        status: ProjectOSStepStatus,
        result: String,
        command: String = "",
        now: Date
    ) {
        guard let step = sortedSteps(for: run).first(where: { keys.contains($0.key) && !$0.status.isTerminal }) ??
            sortedSteps(for: run).first(where: { keys.contains($0.key) }) else { return }
        mark(step, status: status, result: result, command: command, now: now)
    }

    private static func mark(
        _ step: ProjectOSStep,
        status: ProjectOSStepStatus,
        result: String,
        command: String = "",
        now: Date
    ) {
        step.status = status
        if !result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            step.resultSummary = result
        }
        if !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            step.command = command
        }
        if step.startedAt == nil, status != .pending {
            step.startedAt = now
        }
        if status.isTerminal {
            step.completedAt = now
            if status == .completed {
                step.proof = result
            }
        }
        step.updatedAt = now
    }

    private static func completeOpenSteps(_ run: ProjectOSRun, result: String, now: Date) {
        for step in sortedSteps(for: run) where !step.status.isTerminal {
            mark(step, status: .completed, result: result, now: now)
        }
    }
}

struct ProjectIntakeDraft: Equatable, Sendable {
    var workingTitle: String
    var projectKind: String
    var platform: String
    var style: String = ""
    var goal: String = ""
    var startingPriorities: String = ""
    var playerExperience: String
    var constraints: String

    static let empty = ProjectIntakeDraft(
        workingTitle: "",
        projectKind: "",
        platform: "",
        style: "",
        goal: "",
        startingPriorities: "",
        playerExperience: "",
        constraints: ""
    )

    var isEmpty: Bool {
        [workingTitle, projectKind, platform, style, goal, startingPriorities, playerExperience, constraints]
            .allSatisfy { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    var seedPrompt: String {
        [
            ("Working title", workingTitle),
            ("Project type", projectKind),
            ("Platform", platform),
            ("Style", style),
            ("Goal", goal),
            ("Starting priorities", startingPriorities),
            ("Experience", playerExperience),
            ("Constraints", constraints)
        ]
        .compactMap { label, value in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : "\(label): \(trimmed)"
        }
        .joined(separator: "\n")
    }

    var missionText: String {
        let kind = projectKind.trimmingCharacters(in: .whitespacesAndNewlines)
        let experience = playerExperience.trimmingCharacters(in: .whitespacesAndNewlines)
        let platform = platform.trimmingCharacters(in: .whitespacesAndNewlines)
        let style = style.trimmingCharacters(in: .whitespacesAndNewlines)
        let goal = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        let constraints = constraints.trimmingCharacters(in: .whitespacesAndNewlines)

        var pieces: [String] = []
        if !kind.isEmpty {
            pieces.append("Build \(kind)")
        } else {
            pieces.append("Build and verify a focused project")
        }
        if !experience.isEmpty {
            pieces.append("that feels like \(experience)")
        }
        if !style.isEmpty {
            pieces.append("with a \(style) style")
        }
        if !platform.isEmpty {
            pieces.append("for \(platform)")
        }
        if !goal.isEmpty {
            pieces.append("so it can \(goal)")
        }
        if !constraints.isEmpty {
            pieces.append("while respecting \(constraints)")
        }
        return pieces.joined(separator: " ") + "."
    }

    var firstNextStep: String {
        if isGameProject {
            return "Define the core loop, first playable scene, controls, and proof check."
        }
        if isAppProject {
            return "Define the primary user flow, first screen, data needs, and proof check."
        }
        return "Turn the brief into the first concrete build task and proof check."
    }

    var initialAgentTasks: [String] {
        let platformText = platform.trimmingCharacters(in: .whitespacesAndNewlines)
        let platformSuffix = platformText.isEmpty ? "" : " for \(platformText)"
        let goalText = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        let styleText = style.trimmingCharacters(in: .whitespacesAndNewlines)
        let priorityTasks = startingPriorities
            .split(whereSeparator: { ",;\n".contains($0) })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .prefix(3)
            .map { "Prioritize \($0)\(platformSuffix)." }
        if !priorityTasks.isEmpty {
            var tasks = Array(priorityTasks)
            if !goalText.isEmpty {
                tasks.append("Verify the first slice proves the goal: \(goalText).")
            } else {
                tasks.append("Run the fastest relevant proof check and record what changed.")
            }
            return tasks
        }
        if isGameProject {
            return [
                goalText.isEmpty ? "Lock the core loop and player objective\(platformSuffix)." : "Shape the core loop around the goal: \(goalText).",
                styleText.isEmpty ? "Build or outline the first playable scene, controls, and feedback." : "Make the first playable scene feel \(styleText) through controls, pacing, and feedback.",
                "Run the fastest proof check for feel, readability, and a screenshot or artifact."
            ]
        }
        if isAppProject {
            return [
                goalText.isEmpty ? "Map the primary user flow\(platformSuffix)." : "Map the primary user flow that proves: \(goalText).",
                styleText.isEmpty ? "Build or outline the first useful screen and data path." : "Build or outline the first useful screen with a \(styleText) interaction style.",
                "Run the fastest proof check for the flow, layout, and saved artifact."
            ]
        }
        return [
            "Turn the brief into one concrete build target\(platformSuffix).",
            "Create the smallest useful artifact or implementation step.",
            "Run the fastest relevant proof check and record what changed."
        ]
    }

    var initialTaskPreview: String {
        initialAgentTasks.joined(separator: " ")
    }

    var firstRunOperatorNote: String {
        "Use the project intake to choose the first tasks: \(initialAgentTasks.joined(separator: " "))"
    }

    private var isGameProject: Bool {
        let lower = projectKind.lowercased()
        return lower.contains("game") ||
            lower.contains("roguelite") ||
            lower.contains("platformer") ||
            lower.contains("arcade") ||
            lower.contains("puzzle") ||
            lower.contains("rpg") ||
            lower.contains("shooter")
    }

    private var isAppProject: Bool {
        let lower = projectKind.lowercased()
        return lower.contains("app") ||
            lower.contains("tool") ||
            lower.contains("dashboard") ||
            lower.contains("site") ||
            lower.contains("website")
    }
}

struct ProjectEditDraft: Equatable {
    var name: String
    var mission: String
    var workspaceName: String
    var nextStep: String
    var blocker: String
    var status: ProjectState

    init(
        name: String,
        mission: String,
        workspaceName: String,
        nextStep: String,
        blocker: String,
        status: ProjectState
    ) {
        self.name = name
        self.mission = mission
        self.workspaceName = workspaceName
        self.nextStep = nextStep
        self.blocker = blocker
        self.status = status
    }

    init(project: Project) {
        self.init(
            name: project.name,
            mission: project.mission,
            workspaceName: project.workspaceName,
            nextStep: project.nextStep,
            blocker: project.blocker,
            status: project.status
        )
    }

    var isValid: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !mission.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !workspaceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

enum MissionOSPhase: String, Codable, CaseIterable, Equatable, Sendable {
    case contract
    case plan
    case act
    case verify
    case proof
    case decide

    var displayName: String {
        switch self {
        case .contract: "Contract"
        case .plan: "Plan"
        case .act: "Act"
        case .verify: "Verify"
        case .proof: "Proof"
        case .decide: "Decide"
        }
    }

    var symbolName: String {
        switch self {
        case .contract: "doc.text.magnifyingglass"
        case .plan: "list.bullet.clipboard.fill"
        case .act: "hammer.fill"
        case .verify: "checkmark.shield.fill"
        case .proof: "checkmark.seal.fill"
        case .decide: "arrow.triangle.branch"
        }
    }
}

enum MissionOSGateState: String, Codable, CaseIterable, Equatable, Sendable {
    case satisfied
    case waiting
    case blocked

    var displayName: String {
        switch self {
        case .satisfied: "Ready"
        case .waiting: "Waiting"
        case .blocked: "Blocked"
        }
    }

    var symbolName: String {
        switch self {
        case .satisfied: "checkmark.circle.fill"
        case .waiting: "hourglass"
        case .blocked: "exclamationmark.triangle.fill"
        }
    }
}

struct MissionOSGate: Identifiable, Equatable, Sendable {
    var id: String
    var title: String
    var detail: String
    var state: MissionOSGateState
    var weight: Int

    var isBlocking: Bool { state == .blocked }
}

struct MissionOSContract: Equatable, Sendable {
    var headline: String
    var operatorDirective: String
    var phase: MissionOSPhase
    var recommendedIntent: ProjectCommandIntent
    var successCriteria: [String]
    var proofRequirement: String
    var nextAction: String
    var decisionLabel: String
    var readinessScore: Int
    var gates: [MissionOSGate]

    var blockingGates: [MissionOSGate] {
        gates.filter(\.isBlocking)
    }

    var gateSummary: String {
        let ready = gates.filter { $0.state == .satisfied }.count
        return "\(ready)/\(gates.count) gates ready"
    }
}

struct MissionOSCheckpoint: Equatable, Sendable {
    static let metadataKind = "missionOSCheckpoint"
    static let schemaVersion = "1"

    var phase: MissionOSPhase
    var readinessScore: Int
    var decisionLabel: String
    var recommendedIntent: ProjectCommandIntent
    var gateSummary: String
    var blockingGateIDs: [String]
    var proofRequirement: String
    var operatorDirective: String
    var nextAction: String
    var trigger: String

    init(contract: MissionOSContract, trigger: String) {
        self.phase = contract.phase
        self.readinessScore = contract.readinessScore
        self.decisionLabel = contract.decisionLabel
        self.recommendedIntent = contract.recommendedIntent
        self.gateSummary = contract.gateSummary
        self.blockingGateIDs = contract.blockingGates.map(\.id)
        self.proofRequirement = contract.proofRequirement
        self.operatorDirective = contract.operatorDirective
        self.nextAction = contract.nextAction
        self.trigger = trigger
    }

    init?(event: ProjectEvent) {
        guard event.kind == .missionCheckpoint else { return nil }
        let metadata = event.metadata
        guard metadata["kind"] == Self.metadataKind,
              metadata["schemaVersion"] == Self.schemaVersion,
              let phaseRaw = metadata["phase"],
              let phase = MissionOSPhase(rawValue: phaseRaw),
              let readinessRaw = metadata["readinessScore"],
              let readinessScore = Int(readinessRaw),
              let intentRaw = metadata["recommendedIntent"],
              let recommendedIntent = ProjectCommandIntent(rawValue: intentRaw) else {
            return nil
        }
        self.phase = phase
        self.readinessScore = readinessScore
        self.decisionLabel = metadata["decisionLabel"] ?? ""
        self.recommendedIntent = recommendedIntent
        self.gateSummary = metadata["gateSummary"] ?? ""
        self.blockingGateIDs = (metadata["blockingGateIDs"] ?? "")
            .split(separator: ",")
            .map(String.init)
        self.proofRequirement = metadata["proofRequirement"] ?? ""
        self.operatorDirective = metadata["operatorDirective"] ?? event.detail
        self.nextAction = metadata["nextAction"] ?? ""
        self.trigger = metadata["trigger"] ?? ""
    }

    var metadata: [String: String] {
        [
            "kind": Self.metadataKind,
            "schemaVersion": Self.schemaVersion,
            "phase": phase.rawValue,
            "readinessScore": "\(readinessScore)",
            "decisionLabel": decisionLabel,
            "recommendedIntent": recommendedIntent.rawValue,
            "gateSummary": gateSummary,
            "blockingGateIDs": blockingGateIDs.joined(separator: ","),
            "proofRequirement": proofRequirement,
            "operatorDirective": operatorDirective,
            "nextAction": nextAction,
            "trigger": trigger
        ]
    }

    var eventSeverity: ProjectEventSeverity {
        if !blockingGateIDs.isEmpty { return .warning }
        if readinessScore >= 85 { return .success }
        switch phase {
        case .plan, .act, .verify:
            return .running
        case .contract, .proof, .decide:
            return .info
        }
    }
}

struct ProjectRunLogCleanupResult: Equatable {
    var artifactLinksDetached = 0
    var terminalLinksDetached = 0
    var fileChangeLinksDetached = 0
    var eventLinksDetached = 0

    var totalDetachedLinks: Int {
        artifactLinksDetached + terminalLinksDetached + fileChangeLinksDetached + eventLinksDetached
    }
}

enum ProjectRunLogCleanup {
    @discardableResult
    static func detachDeletedRunProvenance(for run: ToolRun, context: ModelContext) throws -> ProjectRunLogCleanupResult {
        let sourceID = run.id.uuidString
        var result = ProjectRunLogCleanupResult()

        let artifacts = try context.fetch(FetchDescriptor<ProjectArtifact>())
        for artifact in artifacts where artifact.sourceToolRunIDString == sourceID {
            artifact.sourceToolRunIDString = nil
            result.artifactLinksDetached += 1
        }

        let terminalCommands = try context.fetch(FetchDescriptor<TerminalCommandRecord>())
        for command in terminalCommands where command.sourceToolRunIDString == sourceID {
            command.sourceToolRunIDString = nil
            result.terminalLinksDetached += 1
        }

        let fileChanges = try context.fetch(FetchDescriptor<ProjectFileChange>())
        for change in fileChanges where change.sourceToolRunIDString == sourceID {
            change.sourceToolRunIDString = nil
            result.fileChangeLinksDetached += 1
        }

        let events = try context.fetch(FetchDescriptor<ProjectEvent>())
        for event in events where event.sourceType == .toolRun && event.sourceIDString == sourceID {
            event.sourceType = nil
            event.sourceIDString = nil
            result.eventLinksDetached += 1
        }

        return result
    }
}

struct ProjectTimelineItem: Identifiable, Equatable {
    var id: String
    var title: String
    var detail: String
    var kindTitle: String
    var createdAt: Date
    var severity: ProjectEventSeverity
    var sourceKind: ProjectEventKind?
}

struct ProjectProofItem: Identifiable, Equatable {
    var id: String
    var title: String
    var detail: String
    var createdAt: Date
    var symbolName: String
    var sourcePath: String?
    var severity: ProjectEventSeverity = .success
}

struct ProjectWorkflowSpine: Equatable, Sendable {
    var currentTitle: String
    var currentDetail: String
    var changedTitle: String
    var changedDetail: String
    var proofTitle: String
    var proofDetail: String
    var blockerTitle: String
    var blockerDetail: String
    var nextActionTitle: String
    var nextActionDetail: String
    var iterationPrompt: String
    var latestArtifactPath: String?
    var latestChangedPath: String?
    var latestTerminalCommand: String?
}

enum ProjectReviewRecommendation: String, Codable, CaseIterable, Equatable, Sendable {
    case continueMission
    case verifyWork
    case askUser
    case fixBlocker
    case finalReview

    var displayName: String {
        switch self {
        case .continueMission: "Continue"
        case .verifyWork: "Verify"
        case .askUser: "Ask User"
        case .fixBlocker: "Fix Blocker"
        case .finalReview: "Final Review"
        }
    }

    var symbolName: String {
        switch self {
        case .continueMission: "arrow.triangle.2.circlepath"
        case .verifyWork: "checkmark.shield.fill"
        case .askUser: "person.crop.circle.badge.questionmark"
        case .fixBlocker: "wrench.and.screwdriver.fill"
        case .finalReview: "flag.checkered"
        }
    }
}

struct ProjectReviewFinding: Identifiable, Equatable, Sendable {
    var id: String
    var title: String
    var detail: String
    var severity: ProjectEventSeverity
    var symbolName: String
}

struct ProjectReviewSummary: Equatable, Sendable {
    var headline: String
    var detail: String
    var recommendation: ProjectReviewRecommendation
    var healthScore: Int
    var proofFreshness: String
    var evidenceTrail: String
    var findings: [ProjectReviewFinding]

    var riskCount: Int {
        findings.filter { $0.severity == .warning || $0.severity == .failure }.count
    }

    var primaryFinding: ProjectReviewFinding? {
        findings.first { $0.severity == .failure } ??
            findings.first { $0.severity == .warning } ??
            findings.first
    }

    var hasWrongProjectRisk: Bool {
        findings.contains { $0.id == "wrong-project-risk" }
    }

    var hasStaleProof: Bool {
        findings.contains { $0.id == "stale-proof" }
    }

    var hasMissingEvidence: Bool {
        findings.contains { $0.id == "missing-evidence" || $0.id == "missing-verification" || $0.id == "missing-proof" }
    }
}

struct ProjectMissionSummary: Equatable {
    var status: ProjectState
    var statusKind: ProjectMissionStatusKind
    var statusText: String
    var missionText: String
    var conversationCount: Int
    var toolRunCount: Int
    var terminalCommandCount: Int
    var artifactCount: Int
    var fileChangeCount: Int
    var eventCount: Int
    var failureCount: Int
    var pendingApprovalCount: Int
    var lastEventTitle: String
    var lastEventDetail: String
    var nextStep: String
    var latestProofTitle: String
    var blocker: String
    var timelineItems: [ProjectTimelineItem]
    var proofItems: [ProjectProofItem]
    var missionContract: MissionOSContract
    var review: ProjectReviewSummary
    var workflowSpine: ProjectWorkflowSpine

    var trustText: String {
        if failureCount > 0 { return "\(failureCount) issue\(failureCount == 1 ? "" : "s") need review" }
        if pendingApprovalCount > 0 { return "\(pendingApprovalCount) approval\(pendingApprovalCount == 1 ? "" : "s") waiting" }
        if toolRunCount + terminalCommandCount + artifactCount + fileChangeCount == 0 { return "No project actions recorded yet" }
        return "Timeline is current"
    }
}

private struct ProjectEvidenceFreshness: Equatable {
    var hasAnyProof: Bool
    var hasCurrentProof: Bool
    var hasAnyVerification: Bool
    var hasCurrentVerification: Bool
    var latestProofAt: Date?
    var latestVerificationAt: Date?
    var latestInvalidatingWorkAt: Date?

    static func make(
        proofItems: [ProjectProofItem],
        toolRuns: [ToolRun],
        terminalCommands: [TerminalCommandRecord],
        fileChanges: [ProjectFileChange],
        events: [ProjectEvent]
    ) -> ProjectEvidenceFreshness {
        let meaningfulProofItems = proofItems.filter { !$0.title.localizedCaseInsensitiveContains("Project created") }
        let latestProofAt = meaningfulProofItems
            .filter { $0.severity == .success || $0.severity == .info }
            .map(\.createdAt)
            .max()
        let verificationRuns = toolRuns.filter { $0.status == .completed && isVerificationToken($0.name) }
        let verificationRunIDs = Set(verificationRuns.map { $0.id.uuidString })
        let verificationDates = verificationRuns.map { $0.completedAt ?? $0.createdAt } +
            terminalCommands
                .filter { $0.status == .completed && isVerificationCommand($0.command) }
                .map(\.completedAt)
        let latestVerificationAt = verificationDates.max()
        let latestProofInvalidatingWorkAt = latestInvalidatingWorkDate(
            toolRuns: toolRuns,
            fileChanges: fileChanges,
            events: events,
            verificationRunIDsToIgnore: []
        )
        let latestVerificationInvalidatingWorkAt = latestInvalidatingWorkDate(
            toolRuns: toolRuns,
            fileChanges: fileChanges,
            events: events,
            verificationRunIDsToIgnore: verificationRunIDs
        )
        let hasAnyProof = latestProofAt != nil
        let hasAnyVerification = latestVerificationAt != nil
        return ProjectEvidenceFreshness(
            hasAnyProof: hasAnyProof,
            hasCurrentProof: hasAnyProof && isFresh(latestProofAt, against: latestProofInvalidatingWorkAt),
            hasAnyVerification: hasAnyVerification,
            hasCurrentVerification: hasAnyVerification && isFresh(latestVerificationAt, against: latestVerificationInvalidatingWorkAt),
            latestProofAt: latestProofAt,
            latestVerificationAt: latestVerificationAt,
            latestInvalidatingWorkAt: latestProofInvalidatingWorkAt
        )
    }

    private static func latestInvalidatingWorkDate(
        toolRuns: [ToolRun],
        fileChanges: [ProjectFileChange],
        events: [ProjectEvent],
        verificationRunIDsToIgnore: Set<String>
    ) -> Date? {
        var dates: [Date] = []
        dates += toolRuns.compactMap { run in
            guard run.isMutating, !verificationRunIDsToIgnore.contains(run.id.uuidString) else { return nil }
            return run.completedAt ?? run.createdAt
        }
        dates += fileChanges.compactMap { change in
            if let sourceID = change.sourceToolRunIDString,
               verificationRunIDsToIgnore.contains(sourceID) {
                return nil
            }
            return change.createdAt
        }
        dates += events.compactMap { event in
            switch event.kind {
            case .agentPlanCreated, .toolApprovalRequested, .workspaceChanged:
                return event.createdAt
            default:
                return nil
            }
        }
        return dates.max()
    }

    private static func isFresh(_ proofDate: Date?, against workDate: Date?) -> Bool {
        guard let proofDate else { return false }
        guard let workDate else { return true }
        return proofDate >= workDate.addingTimeInterval(-1)
    }

    private static func isVerificationToken(_ value: String) -> Bool {
        let lower = value.lowercased()
        return lower.contains("test") ||
            lower.contains("build") ||
            lower.contains("validate") ||
            lower.contains("check") ||
            lower.contains("proof") ||
            lower.contains("screenshot") ||
            lower.contains("smoke") ||
            lower.contains("tour") ||
            lower.contains("diff")
    }

    private static func isVerificationCommand(_ command: String) -> Bool {
        let lower = command.lowercased()
        return isVerificationToken(lower) ||
            lower.contains("xcodebuild") ||
            lower.contains("swift test") ||
            lower.contains("npm test")
    }
}

enum MissionOSContractBuilder {
    static func make(
        project: Project,
        missionText: String,
        statusKind: ProjectMissionStatusKind,
        conversations: [Conversation],
        toolRuns: [ToolRun],
        terminalCommands: [TerminalCommandRecord],
        artifacts: [ProjectArtifact],
        fileChanges: [ProjectFileChange],
        events: [ProjectEvent],
        failures: Int,
        pendingApprovals: Int,
        nextStep: String,
        proofItems: [ProjectProofItem],
        activeBlocker: String? = nil
    ) -> MissionOSContract {
        let blocker = (activeBlocker ?? project.blocker).trimmingCharacters(in: .whitespacesAndNewlines)
        let hasFailure = failures > 0 || statusKind == .blocked || !blocker.isEmpty
        let hasPendingApproval = pendingApprovals > 0 || statusKind == .waiting
        let hasSpecificMission = !isGenericMission(missionText) || !ProjectNamingEngine.isGenericName(project.name)
        let meaningfulProofItems = proofItems.filter { !$0.title.localizedCaseInsensitiveContains("Project created") }
        let hasProjectWork = !toolRuns.isEmpty || !terminalCommands.isEmpty || !artifacts.isEmpty || !fileChanges.isEmpty
        let freshness = ProjectEvidenceFreshness.make(
            proofItems: proofItems,
            toolRuns: toolRuns,
            terminalCommands: terminalCommands,
            fileChanges: fileChanges,
            events: events
        )
        let hasProof = freshness.hasCurrentProof
        let hasVerification = freshness.hasCurrentVerification
        let hasPlanCheckpoint = events.contains { $0.kind == .agentPlanCreated }
        let hasProofCheckpoint = events.contains { $0.kind == .agentProofCreated }
        let hasCheckpointPair = hasPlanCheckpoint && hasProofCheckpoint
        let latestProof = meaningfulProofItems.first

        let contractGate = MissionOSGate(
            id: "contract",
            title: "Mission Contract",
            detail: hasSpecificMission ? compact(missionText, limit: 118) : "Name the outcome and success criteria before deep work.",
            state: hasSpecificMission ? .satisfied : .waiting,
            weight: 16
        )
        let actionGate = MissionOSGate(
            id: "action",
            title: "Action Trail",
            detail: hasProjectWork ? "\(toolRuns.count) run(s), \(terminalCommands.count) command(s), \(fileChanges.count) change(s)" : "No project-owned work has been recorded yet.",
            state: hasProjectWork ? .satisfied : .waiting,
            weight: 15
        )
        let checkpointGate = MissionOSGate(
            id: "checkpoints",
            title: "Run Checkpoints",
            detail: checkpointDetail(hasPlanCheckpoint: hasPlanCheckpoint, hasProofCheckpoint: hasProofCheckpoint, hasProjectWork: hasProjectWork),
            state: checkpointState(hasPlanCheckpoint: hasPlanCheckpoint, hasProofCheckpoint: hasProofCheckpoint, hasProjectWork: hasProjectWork, hasFailure: hasFailure),
            weight: 17
        )
        let safetyGate = MissionOSGate(
            id: "safety",
            title: "Safety",
            detail: safetyDetail(hasFailure: hasFailure, failures: failures, pendingApprovals: pendingApprovals, blocker: blocker),
            state: hasFailure ? .blocked : hasPendingApproval ? .waiting : .satisfied,
            weight: 20
        )
        let verificationGate = MissionOSGate(
            id: "verification",
            title: "Verification",
            detail: verificationDetail(
                hasVerification: hasVerification,
                hasAnyVerification: freshness.hasAnyVerification,
                hasProjectWork: hasProjectWork
            ),
            state: hasFailure ? .blocked : hasVerification ? .satisfied : .waiting,
            weight: 18
        )
        let proofGate = MissionOSGate(
            id: "proof",
            title: "Proof",
            detail: proofDetail(
                latestProof: latestProof,
                hasCurrentProof: hasProof,
                hasAnyProof: freshness.hasAnyProof
            ),
            state: hasFailure ? .blocked : hasProof ? .satisfied : .waiting,
            weight: 14
        )
        let gates = [contractGate, actionGate, checkpointGate, safetyGate, verificationGate, proofGate]
        let score = readinessScore(for: gates)
        let phase = phase(
            hasSpecificMission: hasSpecificMission,
            hasPlanCheckpoint: hasPlanCheckpoint,
            hasProofCheckpoint: hasProofCheckpoint,
            hasProjectWork: hasProjectWork,
            hasVerification: hasVerification,
            hasProof: hasProof,
            hasFailure: hasFailure,
            hasPendingApproval: hasPendingApproval,
            statusKind: statusKind
        )
        let recommendedIntent = recommendedIntent(
            hasSpecificMission: hasSpecificMission,
            hasPlanCheckpoint: hasPlanCheckpoint,
            hasProjectWork: hasProjectWork,
            hasVerification: hasVerification,
            hasProof: hasProof,
            hasAnyProof: freshness.hasAnyProof,
            hasFailure: hasFailure,
            hasPendingApproval: hasPendingApproval,
            nextStep: nextStep,
            artifactCount: artifacts.count
        )

        return MissionOSContract(
            headline: headline(phase: phase, score: score, hasFailure: hasFailure, hasPendingApproval: hasPendingApproval, hasCheckpointPair: hasCheckpointPair),
            operatorDirective: operatorDirective(phase: phase, recommendedIntent: recommendedIntent, nextStep: nextStep),
            phase: phase,
            recommendedIntent: recommendedIntent,
            successCriteria: successCriteria(missionText: missionText, hasSpecificMission: hasSpecificMission),
            proofRequirement: proofRequirement(
                hasVerification: hasVerification,
                hasProof: hasProof,
                hasAnyVerification: freshness.hasAnyVerification,
                hasAnyProof: freshness.hasAnyProof,
                hasCheckpointPair: hasCheckpointPair,
                latestProof: latestProof
            ),
            nextAction: compact(nextStep.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? recommendedIntent.instructionFocus : nextStep, limit: 180),
            decisionLabel: decisionLabel(score: score, hasFailure: hasFailure, hasPendingApproval: hasPendingApproval, hasVerification: hasVerification, hasProof: hasProof, hasCheckpointPair: hasCheckpointPair),
            readinessScore: score,
            gates: gates
        )
    }

    private static func phase(
        hasSpecificMission: Bool,
        hasPlanCheckpoint: Bool,
        hasProofCheckpoint: Bool,
        hasProjectWork: Bool,
        hasVerification: Bool,
        hasProof: Bool,
        hasFailure: Bool,
        hasPendingApproval: Bool,
        statusKind: ProjectMissionStatusKind
    ) -> MissionOSPhase {
        if hasFailure || hasPendingApproval || statusKind == .blocked || statusKind == .waiting { return .decide }
        if !hasSpecificMission { return .contract }
        if !hasPlanCheckpoint { return .plan }
        if !hasProjectWork { return .act }
        if !hasVerification { return .verify }
        if !hasProof || !hasProofCheckpoint { return .proof }
        return .decide
    }

    private static func recommendedIntent(
        hasSpecificMission: Bool,
        hasPlanCheckpoint: Bool,
        hasProjectWork: Bool,
        hasVerification: Bool,
        hasProof: Bool,
        hasAnyProof: Bool,
        hasFailure: Bool,
        hasPendingApproval: Bool,
        nextStep: String,
        artifactCount: Int
    ) -> ProjectCommandIntent {
        if hasFailure { return .fixBlocker }
        if hasPendingApproval { return .reviewEvidence }
        if !hasSpecificMission || !hasPlanCheckpoint { return .planNext }
        if !hasProjectWork { return .continueMission }
        if !hasVerification || !hasProof { return .verifyWork }
        if hasProof { return .reviewEvidence }
        let next = nextStep.lowercased()
        if artifactCount > 0, next.contains("proof") || next.contains("artifact") || next.contains("preview") {
            return .improveArtifact
        }
        return .continueMission
    }

    private static func readinessScore(for gates: [MissionOSGate]) -> Int {
        let possible = max(gates.map(\.weight).reduce(0, +), 1)
        let earned = gates.reduce(0) { total, gate in
            switch gate.state {
            case .satisfied:
                return total + gate.weight
            case .waiting:
                return total + max(0, gate.weight / 3)
            case .blocked:
                return total
            }
        }
        return min(100, max(0, Int((Double(earned) / Double(possible) * 100).rounded())))
    }

    private static func hasCompletedVerification(
        toolRuns: [ToolRun],
        terminalCommands: [TerminalCommandRecord]
    ) -> Bool {
        toolRuns.contains { run in
            run.status == .completed && isVerificationToken(run.name)
        } || terminalCommands.contains { command in
            command.status == .completed && isVerificationCommand(command.command)
        }
    }

    private static func isVerificationToken(_ value: String) -> Bool {
        let lower = value.lowercased()
        return lower.contains("test") ||
            lower.contains("build") ||
            lower.contains("validate") ||
            lower.contains("check") ||
            lower.contains("proof") ||
            lower.contains("screenshot") ||
            lower.contains("smoke") ||
            lower.contains("tour") ||
            lower.contains("diff")
    }

    private static func isVerificationCommand(_ command: String) -> Bool {
        let lower = command.lowercased()
        return isVerificationToken(lower) ||
            lower.contains("xcodebuild") ||
            lower.contains("swift test") ||
            lower.contains("npm test")
    }

    private static func checkpointDetail(
        hasPlanCheckpoint: Bool,
        hasProofCheckpoint: Bool,
        hasProjectWork: Bool
    ) -> String {
        if hasPlanCheckpoint, hasProofCheckpoint {
            return "Agent Plan and Agent Proof are both recorded in the project ledger."
        }
        if hasPlanCheckpoint {
            return "Agent Plan is recorded; Agent Proof still needs to close the run."
        }
        if hasProofCheckpoint {
            return "Agent Proof exists, but the starting Agent Plan is missing."
        }
        if hasProjectWork {
            return "Work exists without a complete plan/proof checkpoint pair."
        }
        return "No agent run checkpoints have been recorded yet."
    }

    private static func checkpointState(
        hasPlanCheckpoint: Bool,
        hasProofCheckpoint: Bool,
        hasProjectWork: Bool,
        hasFailure: Bool
    ) -> MissionOSGateState {
        if hasPlanCheckpoint, hasProofCheckpoint { return .satisfied }
        if hasFailure, hasProjectWork { return .blocked }
        return .waiting
    }

    private static func safetyDetail(hasFailure: Bool, failures: Int, pendingApprovals: Int, blocker: String) -> String {
        if hasFailure {
            if !blocker.isEmpty { return compact(blocker, limit: 118) }
            return "\(max(failures, 1)) issue\(failures == 1 ? "" : "s") need review before more autonomous work."
        }
        if pendingApprovals > 0 {
            return "\(pendingApprovals) approval\(pendingApprovals == 1 ? "" : "s") waiting."
        }
        return "No blocker or failed evidence is currently active."
    }

    private static func verificationDetail(hasVerification: Bool, hasAnyVerification: Bool, hasProjectWork: Bool) -> String {
        if hasVerification { return "A completed check, build, test, validation, or proof command is recorded." }
        if hasAnyVerification { return "Verification exists, but newer project activity needs a fresh check." }
        if hasProjectWork { return "Project work exists; run a check before calling it done." }
        return "Verification starts after the first concrete action."
    }

    private static func proofDetail(
        latestProof: ProjectProofItem?,
        hasCurrentProof: Bool,
        hasAnyProof: Bool
    ) -> String {
        if hasCurrentProof {
            return latestProof.map { "\($0.title) · \($0.detail)" } ?? "Proof is current."
        }
        if hasAnyProof {
            return latestProof.map { "\($0.title) needs refresh for newer project activity." } ?? "Proof exists, but it needs refresh."
        }
        return "No openable proof item is ready yet."
    }

    private static func headline(phase: MissionOSPhase, score: Int, hasFailure: Bool, hasPendingApproval: Bool, hasCheckpointPair: Bool) -> String {
        if hasFailure { return "Blocked until failed evidence is resolved" }
        if hasPendingApproval { return "Waiting for review or approval" }
        if score >= 85, hasCheckpointPair { return "Ready for decision with proof" }
        return "\(phase.displayName) phase · \(score)% ready"
    }

    private static func operatorDirective(
        phase: MissionOSPhase,
        recommendedIntent: ProjectCommandIntent,
        nextStep: String
    ) -> String {
        let next = nextStep.trimmingCharacters(in: .whitespacesAndNewlines)
        if !next.isEmpty {
            return compact("\(recommendedIntent.displayName): \(next)", limit: 180)
        }
        switch phase {
        case .contract:
            return "Clarify the project contract before executing broad changes."
        case .plan:
            return "Inspect the workspace and choose one concrete next action."
        case .act:
            return "Make the smallest useful project-owned change."
        case .verify:
            return "Run checks and capture proof before declaring progress."
        case .proof:
            return "Attach or preview the strongest artifact/result."
        case .decide:
            return "Review evidence and choose continue, fix, or complete."
        }
    }

    private static func proofRequirement(
        hasVerification: Bool,
        hasProof: Bool,
        hasAnyVerification: Bool,
        hasAnyProof: Bool,
        hasCheckpointPair: Bool,
        latestProof: ProjectProofItem?
    ) -> String {
        if hasAnyVerification, !hasVerification {
            return "Re-run verification for the latest project change before review."
        }
        if hasAnyProof, !hasProof {
            return "Refresh proof for the latest iteration before review."
        }
        if hasVerification, hasProof, !hasCheckpointPair {
            return "Close the run with Agent Plan and Agent Proof checkpoints before review."
        }
        if hasVerification, hasProof {
            return latestProof.map { "Use \($0.title) as the current receipt." } ?? "Use the latest proof ledger item."
        }
        if !hasVerification, hasProof {
            return "Proof exists, but it still needs a check/build/test/validation receipt."
        }
        return "Create an openable artifact, changed file, completed run, terminal proof, or fast screenshot proof before review."
    }

    private static func decisionLabel(
        score: Int,
        hasFailure: Bool,
        hasPendingApproval: Bool,
        hasVerification: Bool,
        hasProof: Bool,
        hasCheckpointPair: Bool
    ) -> String {
        if hasFailure { return "Fix blocker" }
        if hasPendingApproval { return "Review approval" }
        if score >= 85 && hasVerification && hasProof && hasCheckpointPair { return "Ready to review" }
        if !hasCheckpointPair { return "Needs checkpoint" }
        if !hasVerification { return "Needs verification" }
        if !hasProof { return "Needs proof" }
        return "Continue mission"
    }

    private static func successCriteria(missionText: String, hasSpecificMission: Bool) -> [String] {
        let missionLine = hasSpecificMission ? "Outcome stays scoped to \(compact(missionText, limit: 96))." : "Outcome is named before broad execution."
        return [
            missionLine,
            "Every run starts with a concrete plan and ends with Agent Proof.",
            "Mutating work is tied to project-owned files, runs, or terminal records.",
            "A check, build, test, validation, or explicit proof review happens before done.",
            "The next action is clear: continue, verify, fix, review, or complete."
        ]
    }

    private static func isGenericMission(_ mission: String) -> Bool {
        let lower = mission.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if lower.isEmpty { return true }
        return lower == "build and verify useful work in novaforge." ||
            lower == "plan, build, and verify one focused outcome." ||
            lower == "send the first project request."
    }

    private static func compact(_ text: String, limit: Int) -> String {
        let oneLine = text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard oneLine.count > limit else { return oneLine }
        return String(oneLine.prefix(max(0, limit - 1))) + "…"
    }
}

enum ProjectReviewBuilder {
    static func make(
        project: Project,
        statusKind: ProjectMissionStatusKind,
        toolRuns: [ToolRun],
        terminalCommands: [TerminalCommandRecord],
        artifacts: [ProjectArtifact],
        fileChanges: [ProjectFileChange],
        events: [ProjectEvent],
        failures: Int,
        pendingApprovals: Int,
        activeBlocker: String,
        proofItems: [ProjectProofItem],
        missionContract: MissionOSContract
    ) -> ProjectReviewSummary {
        let meaningfulProofItems = proofItems.filter { !$0.title.localizedCaseInsensitiveContains("Project created") }
        let hasProjectWork = !toolRuns.isEmpty || !terminalCommands.isEmpty || !artifacts.isEmpty || !fileChanges.isEmpty
        let checkpointGate = missionContract.gates.first { $0.id == "checkpoints" }
        let verificationGate = missionContract.gates.first { $0.id == "verification" }
        let proofGate = missionContract.gates.first { $0.id == "proof" }
        let contractGate = missionContract.gates.first { $0.id == "contract" }
        let freshness = ProjectEvidenceFreshness.make(
            proofItems: proofItems,
            toolRuns: toolRuns,
            terminalCommands: terminalCommands,
            fileChanges: fileChanges,
            events: events
        )
        let staleProof = freshness.hasAnyProof && !freshness.hasCurrentProof
        let workspaceMismatches = terminalCommands.filter { command in
            !command.workspaceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                command.workspaceName != project.workspaceName
        }
        let blocker = activeBlocker.trimmingCharacters(in: .whitespacesAndNewlines)

        var findings: [ProjectReviewFinding] = []
        if !workspaceMismatches.isEmpty {
            findings.append(ProjectReviewFinding(
                id: "wrong-project-risk",
                title: "Wrong-project risk",
                detail: "\(workspaceMismatches.count) terminal record\(workspaceMismatches.count == 1 ? "" : "s") came from a different workspace.",
                severity: .failure,
                symbolName: "folder.badge.questionmark"
            ))
        }
        if failures > 0 || statusKind == .blocked || !blocker.isEmpty {
            findings.append(ProjectReviewFinding(
                id: "failed-evidence",
                title: "Failed evidence",
                detail: blocker.isEmpty ? "\(max(failures, 1)) failed item\(failures == 1 ? "" : "s") need recovery." : blocker,
                severity: .failure,
                symbolName: "exclamationmark.triangle.fill"
            ))
        }
        if pendingApprovals > 0 || statusKind == .waiting {
            findings.append(ProjectReviewFinding(
                id: "approval-waiting",
                title: "Approval waiting",
                detail: "\(max(pendingApprovals, 1)) approval\(pendingApprovals == 1 ? "" : "s") must be resolved before autonomous continuation.",
                severity: .warning,
                symbolName: "checkmark.shield.fill"
            ))
        }
        if contractGate?.state == .waiting {
            findings.append(ProjectReviewFinding(
                id: "ambiguous-mission",
                title: "Mission needs shape",
                detail: "Name the outcome and success criteria before broad autonomous work.",
                severity: .warning,
                symbolName: "doc.text.magnifyingglass"
            ))
        }
        if hasProjectWork, checkpointGate?.state != .satisfied {
            findings.append(ProjectReviewFinding(
                id: "incomplete-handoff",
                title: "Incomplete handoff",
                detail: checkpointGate?.detail ?? "Record Agent Plan and Agent Proof checkpoints around project work.",
                severity: .warning,
                symbolName: "point.3.connected.trianglepath.dotted"
            ))
        }
        if hasProjectWork, verificationGate?.state == .waiting {
            findings.append(ProjectReviewFinding(
                id: "missing-verification",
                title: "Verification missing",
                detail: verificationGate?.detail ?? "Run a build, test, check, validation, or proof command.",
                severity: .warning,
                symbolName: "checkmark.shield.fill"
            ))
        }
        if hasProjectWork, proofGate?.state == .waiting {
            findings.append(ProjectReviewFinding(
                id: "missing-proof",
                title: "Proof missing",
                detail: proofGate?.detail ?? "Capture a durable artifact, changed file, terminal receipt, or screenshot.",
                severity: .warning,
                symbolName: "checkmark.seal.fill"
            ))
        }
        if hasProjectWork, meaningfulProofItems.isEmpty {
            findings.append(ProjectReviewFinding(
                id: "missing-evidence",
                title: "Evidence trail thin",
                detail: "Project work exists, but no credible proof item is ready to inspect.",
                severity: .warning,
                symbolName: "tray.and.arrow.down.fill"
            ))
        }
        if staleProof {
            findings.append(ProjectReviewFinding(
                id: "stale-proof",
                title: "Proof may be stale",
                detail: "Newer project activity happened after the latest successful proof item.",
                severity: .warning,
                symbolName: "clock.badge.exclamationmark"
            ))
        }
        if !hasProjectWork {
            findings.append(ProjectReviewFinding(
                id: "no-project-work",
                title: "No project work yet",
                detail: "Start with a concrete project action, then capture proof.",
                severity: .info,
                symbolName: "sparkles"
            ))
        }
        if findings.isEmpty {
            findings.append(ProjectReviewFinding(
                id: "healthy-evidence",
                title: "Evidence is aligned",
                detail: "Plan, work, verification, and proof are coherent for the next decision.",
                severity: .success,
                symbolName: "checkmark.seal.fill"
            ))
        }

        let recommendation = recommendation(
            project: project,
            missionContract: missionContract,
            findings: findings,
            failures: failures,
            pendingApprovals: pendingApprovals,
            activeBlocker: blocker,
            staleProof: staleProof
        )
        let healthScore = healthScore(from: findings)
        let headline = headline(for: recommendation, findings: findings, missionContract: missionContract)
        let detail = detail(for: recommendation, findings: findings, missionContract: missionContract)
        let proofFreshness: String = {
            if staleProof { return "Stale proof" }
            if meaningfulProofItems.isEmpty { return "No proof yet" }
            return "Proof current"
        }()
        let evidenceTrail = "\(toolRuns.count) run\(toolRuns.count == 1 ? "" : "s") · \(terminalCommands.count) command\(terminalCommands.count == 1 ? "" : "s") · \(artifacts.count) artifact\(artifacts.count == 1 ? "" : "s") · \(fileChanges.count) change\(fileChanges.count == 1 ? "" : "s")"

        return ProjectReviewSummary(
            headline: headline,
            detail: detail,
            recommendation: recommendation,
            healthScore: healthScore,
            proofFreshness: proofFreshness,
            evidenceTrail: evidenceTrail,
            findings: findings
        )
    }

    private static func recommendation(
        project: Project,
        missionContract: MissionOSContract,
        findings: [ProjectReviewFinding],
        failures: Int,
        pendingApprovals: Int,
        activeBlocker: String,
        staleProof: Bool
    ) -> ProjectReviewRecommendation {
        if findings.contains(where: { $0.id == "wrong-project-risk" }) { return .askUser }
        if failures > 0 || !activeBlocker.isEmpty { return .fixBlocker }
        if pendingApprovals > 0 || findings.contains(where: { $0.id == "approval-waiting" }) { return .askUser }
        if project.status == .completed || missionContract.decisionLabel == "Ready to review" { return .finalReview }
        if missionContract.phase == .contract || findings.contains(where: { $0.id == "ambiguous-mission" }) { return .askUser }
        if staleProof ||
            findings.contains(where: { $0.id == "missing-verification" || $0.id == "missing-proof" || $0.id == "missing-evidence" }) {
            return .verifyWork
        }
        return .continueMission
    }

    private static func healthScore(from findings: [ProjectReviewFinding]) -> Int {
        let penalty = findings.reduce(0) { total, finding in
            switch finding.id {
            case "wrong-project-risk":
                return total + 32
            case "failed-evidence":
                return total + 36
            case "approval-waiting":
                return total + 20
            case "ambiguous-mission":
                return total + 22
            case "incomplete-handoff":
                return total + 12
            case "missing-verification":
                return total + 16
            case "missing-proof", "missing-evidence", "stale-proof":
                return total + 14
            case "no-project-work":
                return total + 10
            default:
                return total
            }
        }
        return min(100, max(0, 100 - penalty))
    }

    private static func headline(
        for recommendation: ProjectReviewRecommendation,
        findings: [ProjectReviewFinding],
        missionContract: MissionOSContract
    ) -> String {
        if let primary = findings.first(where: { $0.id == "wrong-project-risk" }) { return primary.title }
        switch recommendation {
        case .fixBlocker:
            return "Blocked until failed evidence is resolved"
        case .askUser:
            return findings.first(where: { $0.id == "approval-waiting" }) != nil ? "User review required" : "Clarify before autonomy"
        case .verifyWork:
            return "Verification should happen next"
        case .finalReview:
            return "Proof is ready for final review"
        case .continueMission:
            return missionContract.headline
        }
    }

    private static func detail(
        for recommendation: ProjectReviewRecommendation,
        findings: [ProjectReviewFinding],
        missionContract: MissionOSContract
    ) -> String {
        if recommendation == .finalReview {
            return "Review the proof ledger and decide whether to complete or continue."
        }
        if let primary = findings.first(where: { $0.severity == .failure }) ??
            findings.first(where: { $0.severity == .warning }) {
            return primary.detail
        }
        switch recommendation {
        case .finalReview:
            return "Review the proof ledger and decide whether to complete or continue."
        case .continueMission:
            return missionContract.operatorDirective
        case .verifyWork:
            return missionContract.proofRequirement
        case .askUser:
            return "A human decision is needed before NovaForge continues automatically."
        case .fixBlocker:
            return "Start from failed evidence, recover, then verify."
        }
    }
}

enum ProjectMissionSummarizer {
    private struct FailureEvidence {
        var id: String
        var title: String
        var createdAt: Date
    }

    static func summarize(project: Project, context: ModelContext) -> ProjectMissionSummary {
        summarize(
            project: project,
            conversations: (try? context.fetch(FetchDescriptor<Conversation>())) ?? [],
            toolRuns: (try? context.fetch(FetchDescriptor<ToolRun>())) ?? [],
            terminalCommands: (try? context.fetch(FetchDescriptor<TerminalCommandRecord>())) ?? [],
            artifacts: (try? context.fetch(FetchDescriptor<ProjectArtifact>())) ?? [],
            fileChanges: (try? context.fetch(FetchDescriptor<ProjectFileChange>())) ?? [],
            events: (try? context.fetch(FetchDescriptor<ProjectEvent>())) ?? []
        )
    }

    static func summarize(
        project: Project,
        conversations: [Conversation],
        toolRuns: [ToolRun],
        terminalCommands: [TerminalCommandRecord],
        artifacts: [ProjectArtifact],
        fileChanges: [ProjectFileChange],
        events: [ProjectEvent]
    ) -> ProjectMissionSummary {
        let projectID = project.id
        let projectConversations = conversations.filter { $0.project?.id == projectID }
        let projectRuns = toolRuns.filter { $0.project?.id == projectID }
        let projectCommands = terminalCommands.filter { $0.project?.id == projectID }
        let projectArtifacts = artifacts.filter { $0.project?.id == projectID }
        let projectFileChanges = fileChanges.filter { $0.project?.id == projectID }
        let projectEvents = events.filter { $0.project?.id == projectID }
        let failedRuns = projectRuns.filter { $0.status == .failed || $0.status == .rejected }
        let failedCommands = projectCommands.filter { $0.status == .failed }
        let failedRunIDs = Set(
            failedRuns.map { $0.id.uuidString }
        )
        let failedCommandIDs = Set(
            failedCommands.map { $0.id.uuidString }
        )
        let independentFailureEvents = projectEvents.filter { event in
            guard event.severity == .failure else { return false }
            guard let sourceID = event.sourceIDString else { return true }
            switch event.sourceType {
            case .toolRun:
                return !failedRunIDs.contains(sourceID)
            case .terminalCommand:
                return !failedCommandIDs.contains(sourceID)
            default:
                return true
            }
        }
        let allFailures = makeFailureEvidence(
            failedRuns: failedRuns,
            failedCommands: failedCommands,
            independentFailureEvents: independentFailureEvents
        )
        let latestRecoveryAt = latestRecoveryDate(
            toolRuns: projectRuns,
            terminalCommands: projectCommands,
            artifacts: projectArtifacts,
            fileChanges: projectFileChanges,
            events: projectEvents
        )
        let activeFailures = activeFailureEvidence(allFailures, latestRecoveryAt: latestRecoveryAt)
        let failures = activeFailures.count
        let pending = projectRuns.filter { $0.status == .pendingApproval }.count
        let hasApprovedRunningTool = projectRuns.contains { $0.status == .approved }
        let sortedEvents = projectEvents.sorted { lhs, rhs in
            if lhs.createdAt != rhs.createdAt { return lhs.createdAt > rhs.createdAt }
            return lhs.id.uuidString < rhs.id.uuidString
        }
        let timelineItems = makeTimelineItems(from: sortedEvents)
        let proofItems = makeProofItems(
            artifacts: projectArtifacts,
            fileChanges: projectFileChanges,
            toolRuns: projectRuns,
            terminalCommands: projectCommands,
            events: sortedEvents
        )
        let lastEvent = timelineItems.first
        let activeBlocker = activeBlocker(
            project: project,
            activeFailures: activeFailures,
            latestRecoveryAt: latestRecoveryAt
        )
        let hasActiveWaitingEvent = hasActiveWaitingEvent(
            sortedEvents.first,
            latestRecoveryAt: latestRecoveryAt
        )
        let statusKind = missionStatusKind(
            project: project,
            failures: failures,
            pending: pending,
            activeBlocker: activeBlocker,
            hasActiveWaitingEvent: hasActiveWaitingEvent
        )
        let nextStep = recommendedNextStep(
            project: project,
            timelineItems: timelineItems,
            proofItems: proofItems,
            toolRuns: projectRuns,
            terminalCommands: projectCommands,
            artifacts: projectArtifacts,
            fileChanges: projectFileChanges,
            events: projectEvents,
            failures: failures,
            pending: pending,
            activeBlocker: activeBlocker,
            statusKind: statusKind
        )
        let effectiveStatus: ProjectState = {
            switch statusKind {
            case .active: return (project.status == .running || hasApprovedRunningTool) ? .running : .active
            case .waiting: return .needsReview
            case .blocked: return .blocked
            case .done: return .completed
            }
        }()
        let mission = project.mission.trimmingCharacters(in: .whitespacesAndNewlines)
        let missionText = mission.isEmpty ? "Build and verify useful work in NovaForge." : mission
        let missionContract = MissionOSContractBuilder.make(
            project: project,
            missionText: missionText,
            statusKind: statusKind,
            conversations: projectConversations,
            toolRuns: projectRuns,
            terminalCommands: projectCommands,
            artifacts: projectArtifacts,
            fileChanges: projectFileChanges,
            events: projectEvents,
            failures: failures,
            pendingApprovals: pending,
            nextStep: nextStep,
            proofItems: proofItems,
            activeBlocker: activeBlocker
        )
        let review = ProjectReviewBuilder.make(
            project: project,
            statusKind: statusKind,
            toolRuns: projectRuns,
            terminalCommands: projectCommands,
            artifacts: projectArtifacts,
            fileChanges: projectFileChanges,
            events: projectEvents,
            failures: failures,
            pendingApprovals: pending,
            activeBlocker: activeBlocker,
            proofItems: proofItems,
            missionContract: missionContract
        )
        let workflowSpine = makeWorkflowSpine(
            project: project,
            statusKind: statusKind,
            nextStep: nextStep,
            activeBlocker: activeBlocker,
            proofItems: proofItems,
            toolRuns: projectRuns,
            terminalCommands: projectCommands,
            artifacts: projectArtifacts,
            fileChanges: projectFileChanges,
            review: review
        )

        return ProjectMissionSummary(
            status: effectiveStatus,
            statusKind: statusKind,
            statusText: effectiveStatus.displayName,
            missionText: missionText,
            conversationCount: projectConversations.count,
            toolRunCount: projectRuns.count,
            terminalCommandCount: projectCommands.count,
            artifactCount: projectArtifacts.count,
            fileChangeCount: projectFileChanges.count,
            eventCount: projectEvents.count,
            failureCount: failures,
            pendingApprovalCount: pending,
            lastEventTitle: lastEvent?.title ?? "Project created",
            lastEventDetail: lastEvent?.detail ?? "Mission history is ready.",
            nextStep: nextStep,
            latestProofTitle: proofItems.first?.title ?? "No proof captured yet",
            blocker: activeBlocker,
            timelineItems: timelineItems,
            proofItems: proofItems,
            missionContract: missionContract,
            review: review,
            workflowSpine: workflowSpine
        )
    }

    private static func makeWorkflowSpine(
        project: Project,
        statusKind: ProjectMissionStatusKind,
        nextStep: String,
        activeBlocker: String,
        proofItems: [ProjectProofItem],
        toolRuns: [ToolRun],
        terminalCommands: [TerminalCommandRecord],
        artifacts: [ProjectArtifact],
        fileChanges: [ProjectFileChange],
        review: ProjectReviewSummary
    ) -> ProjectWorkflowSpine {
        let latestArtifact = artifacts.sorted { lhs, rhs in
            if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
            return lhs.path < rhs.path
        }.first
        let latestChange = fileChanges.sorted { lhs, rhs in
            if lhs.createdAt != rhs.createdAt { return lhs.createdAt > rhs.createdAt }
            return lhs.path < rhs.path
        }.first
        let latestRun = toolRuns.sorted {
            let lhs = $0.completedAt ?? $0.createdAt
            let rhs = $1.completedAt ?? $1.createdAt
            if lhs != rhs { return lhs > rhs }
            return $0.id.uuidString < $1.id.uuidString
        }.first
        let latestTerminal = terminalCommands.sorted {
            if $0.completedAt != $1.completedAt { return $0.completedAt > $1.completedAt }
            return $0.id.uuidString < $1.id.uuidString
        }.first
        let meaningfulProof = proofItems.first {
            !$0.title.localizedCaseInsensitiveContains("Project created")
        }
        let latestArtifactPath = latestArtifact?.path
        let latestChangedPath: String?
        let changedTitle: String
        let changedDetail: String

        let artifactIsNewest = latestArtifact.map { artifact in
            latestChange.map { artifact.updatedAt >= $0.createdAt } ?? true
        } ?? false
        if artifactIsNewest, let latestArtifact {
            latestChangedPath = latestArtifact.path
            changedTitle = "Artifact ready"
            changedDetail = readablePath(latestArtifact.path)
        } else if let latestChange {
            latestChangedPath = latestChange.path
            changedTitle = latestChange.action.isEmpty ? "File changed" : latestChange.action
            changedDetail = readablePath(latestChange.path)
        } else if let latestRun {
            latestChangedPath = nil
            changedTitle = latestRun.status == .completed ? "Run finished" : toolRunStatusTitle(latestRun.status)
            changedDetail = toolRunDisplayName(latestRun.name)
        } else if let latestTerminal {
            latestChangedPath = nil
            changedTitle = latestTerminal.status == .completed ? "Command finished" : "Command failed"
            changedDetail = cleanDetail(latestTerminal.command)
        } else {
            latestChangedPath = nil
            changedTitle = "No project changes yet"
            changedDetail = "Ask for a concrete project artifact, file change, or verification run."
        }

        let proofTitle: String
        let proofDetail: String
        if review.hasStaleProof, let meaningfulProof {
            proofTitle = "Proof needs refresh"
            proofDetail = "\(meaningfulProof.title) is older than newer project activity."
        } else if let meaningfulProof {
            proofTitle = meaningfulProof.title
            proofDetail = meaningfulProof.detail
        } else {
            proofTitle = "No proof captured yet"
            proofDetail = "Run a check, open an artifact, or save Agent Proof for the latest work."
        }

        let blocker = activeBlocker.trimmingCharacters(in: .whitespacesAndNewlines)
        let blockerTitle: String
        let blockerDetail: String
        if !blocker.isEmpty {
            blockerTitle = "Blocker"
            blockerDetail = blocker
        } else if statusKind == .waiting {
            blockerTitle = "Waiting"
            blockerDetail = "Resolve the pending approval or review gate before continuing."
        } else {
            blockerTitle = "Clear"
            blockerDetail = "No active blocker is recorded."
        }

        let nextActionTitle: String
        switch review.recommendation {
        case .fixBlocker:
            nextActionTitle = "Recover"
        case .verifyWork:
            nextActionTitle = "Verify"
        case .askUser:
            nextActionTitle = "Review"
        case .finalReview:
            nextActionTitle = "Decide"
        case .continueMission:
            nextActionTitle = "Continue"
        }
        let nextActionDetail = nextStep.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? review.detail
            : nextStep
        let currentTitle: String
        let currentDetail: String
        switch statusKind {
        case .blocked:
            currentTitle = "Recovery needed"
            currentDetail = blockerDetail
        case .waiting:
            currentTitle = "Human decision needed"
            currentDetail = blockerDetail
        case .done:
            currentTitle = "Ready for review"
            currentDetail = proofDetail
        case .active:
            currentTitle = nextActionTitle
            currentDetail = nextActionDetail
        }

        let iterationTarget = latestArtifactPath ?? latestChangedPath
        let iterationPrompt: String
        if let iterationTarget {
            iterationPrompt = "Ask for the next change against \(readablePath(iterationTarget)), then verify and update proof."
        } else {
            iterationPrompt = "Ask for one concrete output, then inspect, verify, and capture proof."
        }

        return ProjectWorkflowSpine(
            currentTitle: currentTitle,
            currentDetail: cleanDetail(currentDetail),
            changedTitle: changedTitle,
            changedDetail: cleanDetail(changedDetail),
            proofTitle: proofTitle,
            proofDetail: cleanDetail(proofDetail),
            blockerTitle: blockerTitle,
            blockerDetail: cleanDetail(blockerDetail),
            nextActionTitle: nextActionTitle,
            nextActionDetail: cleanDetail(nextActionDetail),
            iterationPrompt: cleanDetail(iterationPrompt),
            latestArtifactPath: latestArtifactPath,
            latestChangedPath: latestChangedPath,
            latestTerminalCommand: latestTerminal.map { cleanDetail($0.command) }
        )
    }

    private static func makeFailureEvidence(
        failedRuns: [ToolRun],
        failedCommands: [TerminalCommandRecord],
        independentFailureEvents: [ProjectEvent]
    ) -> [FailureEvidence] {
        let runFailures = failedRuns.map { run in
            FailureEvidence(
                id: "run-\(run.id.uuidString)",
                title: run.status == .rejected ? "Run rejected" : "Run failed",
                createdAt: run.completedAt ?? run.createdAt
            )
        }
        let commandFailures = failedCommands.map { command in
            FailureEvidence(
                id: "terminal-\(command.id.uuidString)",
                title: "Command failed",
                createdAt: command.completedAt
            )
        }
        let eventFailures = independentFailureEvents.map { event in
            FailureEvidence(
                id: "event-\(event.id.uuidString)",
                title: event.title.isEmpty ? "Run failed" : event.title,
                createdAt: event.createdAt
            )
        }
        return (runFailures + commandFailures + eventFailures).sorted { lhs, rhs in
            if lhs.createdAt != rhs.createdAt { return lhs.createdAt > rhs.createdAt }
            return lhs.id < rhs.id
        }
    }

    private static func latestRecoveryDate(
        toolRuns: [ToolRun],
        terminalCommands: [TerminalCommandRecord],
        artifacts: [ProjectArtifact],
        fileChanges: [ProjectFileChange],
        events: [ProjectEvent]
    ) -> Date? {
        var dates: [Date] = []
        dates += toolRuns
            .filter { $0.status == .completed && ($0.isMutating || isVerificationToken($0.name)) }
            .compactMap { $0.completedAt ?? $0.createdAt }
        dates += terminalCommands
            .filter { $0.status == .completed && isVerificationCommand($0.command) }
            .map(\.completedAt)
        dates += artifacts.map(\.updatedAt)
        dates += fileChanges.map(\.createdAt)
        dates += events.compactMap { event in
            guard event.severity == .success, eventRepresentsRecovery(event) else { return nil }
            return event.createdAt
        }
        return dates.max()
    }

    private static func eventRepresentsRecovery(_ event: ProjectEvent) -> Bool {
        switch event.kind {
        case .runCompleted, .agentProofCreated, .artifactCreated, .fileChanged, .missionCheckpoint:
            return true
        default:
            return false
        }
    }

    private static func activeFailureEvidence(
        _ failures: [FailureEvidence],
        latestRecoveryAt: Date?
    ) -> [FailureEvidence] {
        guard let latestRecoveryAt else { return failures }
        return failures.filter { $0.createdAt > latestRecoveryAt }
    }

    private static func activeBlocker(
        project: Project,
        activeFailures: [FailureEvidence],
        latestRecoveryAt: Date?
    ) -> String {
        let persisted = project.blocker.trimmingCharacters(in: .whitespacesAndNewlines)
        if let newestFailure = activeFailures.first {
            return persisted.isEmpty ? newestFailure.title : persisted
        }
        guard project.status == .blocked, latestRecoveryAt == nil else {
            return ""
        }
        return persisted
    }

    private static func hasActiveWaitingEvent(
        _ latestEvent: ProjectEvent?,
        latestRecoveryAt: Date?
    ) -> Bool {
        guard let latestEvent,
              latestEvent.severity == .warning || latestEvent.kind == .runPaused else {
            return false
        }
        guard let latestRecoveryAt else { return true }
        return latestEvent.createdAt > latestRecoveryAt
    }

    private static func makeTimelineItems(from events: [ProjectEvent]) -> [ProjectTimelineItem] {
        events.map { event in
            ProjectTimelineItem(
                id: event.id.uuidString,
                title: timelineTitle(for: event),
                detail: cleanDetail(event.detail),
                kindTitle: eventKindTitle(event.kind),
                createdAt: event.createdAt,
                severity: event.severity,
                sourceKind: event.kind
            )
        }
    }

    private static func makeProofItems(
        artifacts: [ProjectArtifact],
        fileChanges: [ProjectFileChange],
        toolRuns: [ToolRun],
        terminalCommands: [TerminalCommandRecord],
        events: [ProjectEvent]
    ) -> [ProjectProofItem] {
        var items: [ProjectProofItem] = []
        for artifact in artifacts.sorted(by: { lhs, rhs in
            if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
            return lhs.path < rhs.path
        }).prefix(4) {
            items.append(ProjectProofItem(
                id: "artifact-\(artifact.id.uuidString)",
                title: artifact.title.isEmpty ? URL(fileURLWithPath: artifact.path).lastPathComponent : artifact.title,
                detail: "Artifact · \(cleanDetail(artifact.path))",
                createdAt: artifact.updatedAt,
                symbolName: artifact.kind == .web ? "play.rectangle.fill" : "shippingbox.fill",
                sourcePath: artifact.path,
                severity: .success
            ))
        }
        for change in fileChanges.sorted(by: { lhs, rhs in
            if lhs.createdAt != rhs.createdAt { return lhs.createdAt > rhs.createdAt }
            return lhs.path < rhs.path
        }).prefix(3) {
            let filename = URL(fileURLWithPath: change.path).lastPathComponent
            items.append(ProjectProofItem(
                id: "file-\(change.id.uuidString)",
                title: "File changed: \(filename.isEmpty ? change.path : filename)",
                detail: cleanDetail(change.path),
                createdAt: change.createdAt,
                symbolName: "doc.text.fill",
                sourcePath: change.path,
                severity: .success
            ))
        }
        for run in toolRuns.filter({ $0.status == .completed }).sorted(by: {
            let lhs = $0.completedAt ?? $0.createdAt
            let rhs = $1.completedAt ?? $1.createdAt
            if lhs != rhs { return lhs > rhs }
            return $0.id.uuidString < $1.id.uuidString
        }).prefix(3) {
            items.append(ProjectProofItem(
                id: "run-\(run.id.uuidString)",
                title: "Run completed",
                detail: run.name,
                createdAt: run.completedAt ?? run.createdAt,
                symbolName: "checkmark.circle.fill",
                sourcePath: nil,
                severity: .success
            ))
        }
        for run in toolRuns.filter({ $0.status == .failed || $0.status == .rejected }).sorted(by: {
            let lhs = $0.completedAt ?? $0.createdAt
            let rhs = $1.completedAt ?? $1.createdAt
            if lhs != rhs { return lhs > rhs }
            return $0.id.uuidString < $1.id.uuidString
        }).prefix(2) {
            items.append(ProjectProofItem(
                id: "run-failure-\(run.id.uuidString)",
                title: run.status == .rejected ? "Run rejected" : "Run failed",
                detail: run.name,
                createdAt: run.completedAt ?? run.createdAt,
                symbolName: "exclamationmark.triangle.fill",
                sourcePath: nil,
                severity: .failure
            ))
        }
        for command in terminalCommands.filter({ $0.status == .completed }).sorted(by: { $0.completedAt > $1.completedAt }).prefix(2) {
            items.append(ProjectProofItem(
                id: "terminal-\(command.id.uuidString)",
                title: "Command completed",
                detail: cleanDetail(command.command),
                createdAt: command.completedAt,
                symbolName: "terminal.fill",
                sourcePath: nil,
                severity: .success
            ))
        }
        for command in terminalCommands.filter({ $0.status == .failed }).sorted(by: { $0.completedAt > $1.completedAt }).prefix(2) {
            items.append(ProjectProofItem(
                id: "terminal-failure-\(command.id.uuidString)",
                title: "Command failed",
                detail: cleanDetail(command.command),
                createdAt: command.completedAt,
                symbolName: "exclamationmark.triangle.fill",
                sourcePath: nil,
                severity: .failure
            ))
        }
        let proofWorthyEventKinds: Set<ProjectEventKind> = [
            .toolCompleted, .runCompleted, .artifactCreated, .artifactPreviewed,
            .fileChanged, .terminalCommand, .agentProofCreated, .missionCheckpoint
        ]
        for event in events.filter({ $0.severity == .success && proofWorthyEventKinds.contains($0.kind) }).prefix(3) {
            items.append(ProjectProofItem(
                id: "event-\(event.id.uuidString)",
                title: timelineTitle(for: event),
                detail: cleanDetail(event.detail),
                createdAt: event.createdAt,
                symbolName: "checkmark.seal.fill",
                sourcePath: nil,
                severity: event.severity
            ))
        }
        return Array(items.sorted { lhs, rhs in
            if lhs.createdAt != rhs.createdAt { return lhs.createdAt > rhs.createdAt }
            return lhs.id < rhs.id
        }.prefix(8))
    }

    private static func recommendedNextStep(
        project: Project,
        timelineItems: [ProjectTimelineItem],
        proofItems: [ProjectProofItem],
        toolRuns: [ToolRun],
        terminalCommands: [TerminalCommandRecord],
        artifacts: [ProjectArtifact],
        fileChanges: [ProjectFileChange],
        events: [ProjectEvent],
        failures: Int,
        pending: Int,
        activeBlocker: String,
        statusKind: ProjectMissionStatusKind
    ) -> String {
        if project.status == .completed { return "Review final proof." }
        if failures > 0 || statusKind == .blocked || !activeBlocker.isEmpty {
            return "Review the failed evidence and retry the run."
        }
        if pending > 0 || statusKind == .waiting {
            return "Review the pending approval."
        }

        let hasProjectWork = !toolRuns.isEmpty || !terminalCommands.isEmpty || !artifacts.isEmpty || !fileChanges.isEmpty
        let freshness = ProjectEvidenceFreshness.make(
            proofItems: proofItems,
            toolRuns: toolRuns,
            terminalCommands: terminalCommands,
            fileChanges: fileChanges,
            events: events
        )
        let hasVerification = freshness.hasCurrentVerification
        let hasPlanCheckpoint = events.contains { $0.kind == .agentPlanCreated }
        let hasProofCheckpoint = events.contains { $0.kind == .agentProofCreated }
        let meaningfulProofItems = proofItems.filter { !$0.title.localizedCaseInsensitiveContains("Project created") }

        if !hasPlanCheckpoint {
            if hasProjectWork {
                return "Record an Agent Plan checkpoint, then continue from the latest evidence."
            }
            let meaningfulTimeline = meaningfulTimelineItems(timelineItems)
            if meaningfulTimeline.isEmpty { return "Send the first project request." }
            return "Plan the next concrete agent step from project evidence."
        }
        if !hasProjectWork {
            let persistedNextStep = project.nextStep.trimmingCharacters(in: .whitespacesAndNewlines)
            if !persistedNextStep.isEmpty,
               persistedNextStep.localizedCaseInsensitiveCompare("Send the first project request.") != .orderedSame {
                return persistedNextStep
            }
            return "Run the first concrete project action."
        }
        if !hasVerification {
            if freshness.hasAnyVerification {
                return "Re-run verification for the latest project change."
            }
            return "Run the fastest verification or screenshot proof check."
        }
        if meaningfulProofItems.isEmpty || !freshness.hasCurrentProof {
            if freshness.hasAnyProof {
                return "Refresh proof for the latest iteration."
            }
            return "Capture durable proof for the latest verified work."
        }
        if !hasProofCheckpoint {
            return "Save Agent Proof for the verified result."
        }
        if !meaningfulProofItems.isEmpty {
            return "Review the latest proof."
        }
        return project.nextStep.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Send the next project request." : project.nextStep
    }

    private static func missionStatusKind(
        project: Project,
        failures: Int,
        pending: Int,
        activeBlocker: String,
        hasActiveWaitingEvent: Bool
    ) -> ProjectMissionStatusKind {
        if project.status == .completed { return .done }
        if failures > 0 || !activeBlocker.isEmpty {
            return .blocked
        }
        if pending > 0 || hasActiveWaitingEvent {
            return .waiting
        }
        return .active
    }

    private static func meaningfulTimelineItems(_ timelineItems: [ProjectTimelineItem]) -> [ProjectTimelineItem] {
        timelineItems.filter { item in
            guard let sourceKind = item.sourceKind else { return true }
            return sourceKind != .projectCreated &&
                sourceKind != .projectSelected &&
                sourceKind != .conversationStarted &&
                sourceKind != .migrationLinked
        }
    }

    private static func hasCompletedVerification(
        toolRuns: [ToolRun],
        terminalCommands: [TerminalCommandRecord]
    ) -> Bool {
        toolRuns.contains { run in
            run.status == .completed && isVerificationToken(run.name)
        } || terminalCommands.contains { command in
            command.status == .completed && isVerificationCommand(command.command)
        }
    }

    private static func isVerificationToken(_ value: String) -> Bool {
        let lower = value.lowercased()
        return lower.contains("test") ||
            lower.contains("build") ||
            lower.contains("validate") ||
            lower.contains("check") ||
            lower.contains("proof") ||
            lower.contains("screenshot") ||
            lower.contains("smoke") ||
            lower.contains("tour") ||
            lower.contains("diff")
    }

    private static func isVerificationCommand(_ command: String) -> Bool {
        let lower = command.lowercased()
        return isVerificationToken(lower) ||
            lower.contains("xcodebuild") ||
            lower.contains("swift test") ||
            lower.contains("npm test")
    }

    private static func timelineTitle(for event: ProjectEvent) -> String {
        switch event.kind {
        case .projectCreated: return "Project created"
        case .projectSelected: return event.title.isEmpty ? "Project selected" : event.title
        case .projectRenamed: return event.title.isEmpty ? "Project renamed" : event.title
        case .conversationContinued: return event.title.isEmpty ? "Project continued" : event.title
        case .conversationStarted: return "Project chat ready"
        case .artifactCreated: return proofTitle(prefix: "Generated proof", detail: event.detail, fallback: event.title)
        case .artifactPreviewed: return "Opened artifact preview"
        case .fileChanged: return proofTitle(prefix: "File changed", detail: event.detail, fallback: event.title)
        case .agentPlanCreated: return event.title.isEmpty ? "Agent plan prepared" : event.title
        case .agentProofCreated: return event.title.isEmpty ? "Agent proof captured" : event.title
        case .missionCheckpoint: return event.title.isEmpty ? "Mission OS checkpoint" : event.title
        case .runCompleted: return "Run completed"
        case .runFailed, .toolFailed: return event.title.isEmpty ? "Run failed" : event.title
        case .toolApprovalRequested: return "Waiting on user"
        case .toolCompleted: return event.title.isEmpty ? "Tool completed" : event.title
        case .workspaceChanged: return "Workspace changed"
        case .settingsChanged: return "Settings changed"
        case .autoContinueEnabled: return "Auto-continue enabled"
        case .autoContinueDisabled: return "Auto-continue disabled"
        case .autoContinueScheduled: return event.title.isEmpty ? "Auto-continue scheduled" : event.title
        case .autoContinueStarted: return event.title.isEmpty ? "Auto-continued run started" : event.title
        case .autoContinuePaused: return event.title.isEmpty ? "Auto-continue paused" : event.title
        default: return event.title.isEmpty ? eventKindTitle(event.kind) : event.title
        }
    }

    private static func proofTitle(prefix: String, detail: String, fallback: String) -> String {
        let name = URL(fileURLWithPath: detail).lastPathComponent
        if !name.isEmpty { return "\(prefix): \(name)" }
        return fallback.isEmpty ? prefix : fallback
    }

    private static func eventKindTitle(_ kind: ProjectEventKind) -> String {
        kind.rawValue
            .replacingOccurrences(of: "([a-z])([A-Z])", with: "$1 $2", options: .regularExpression)
            .capitalized
    }

    private static func cleanDetail(_ text: String) -> String {
        let oneLine = text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !oneLine.isEmpty else { return "Project evidence recorded." }
        return oneLine.count > 160 ? String(oneLine.prefix(159)) + "…" : oneLine
    }

    private static func readablePath(_ path: String) -> String {
        let name = URL(fileURLWithPath: path).lastPathComponent
        return name.isEmpty ? path : name
    }

    private static func toolRunDisplayName(_ name: String) -> String {
        name
            .replacingOccurrences(of: "_", with: " ")
            .split(separator: " ")
            .map { word in
                word.count <= 2 ? String(word) : word.prefix(1).uppercased() + word.dropFirst()
            }
            .joined(separator: " ")
    }

    private static func toolRunStatusTitle(_ status: ToolRunStatus) -> String {
        switch status {
        case .pendingApproval:
            return "Approval pending"
        case .approved:
            return "Approved"
        case .rejected:
            return "Rejected"
        case .completed:
            return "Completed"
        case .failed:
            return "Failed"
        }
    }
}

struct ProjectIdentitySuggestion: Equatable {
    var name: String
    var mission: String
}

enum ProjectNamingEngine {
    static func shouldRename(_ project: Project) -> Bool {
        isGenericProjectName(project.name)
    }

    static func isGenericName(_ name: String) -> Bool {
        isGenericProjectName(name)
    }

    static func suggestedIdentity(
        prompt: String,
        currentProjectName: String,
        currentMission: String,
        existingProjectNames: Set<String>
    ) -> ProjectIdentitySuggestion? {
        guard isGenericProjectName(currentProjectName) else { return nil }
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedMission = currentMission.trimmingCharacters(in: .whitespacesAndNewlines)
        let source = bestNamingSource(prompt: trimmedPrompt, mission: trimmedMission)
        let lower = source.lowercased()
        guard !source.isEmpty else { return nil }
        guard !isGenericProjectName(source) else { return nil }
        guard !isContinuationEnvelope(lower) || !isGenericMission(trimmedMission) else { return nil }

        let baseName = preferredName(from: lower, source: source)
        let uniqueName = uniqueProjectName(baseName, existingProjectNames: existingProjectNames)
        let mission = preferredMission(from: trimmedPrompt, currentMission: trimmedMission, name: uniqueName)
        return ProjectIdentitySuggestion(name: uniqueName, mission: mission)
    }

    static func identitySeed(from conversation: Conversation?) -> String? {
        guard let conversation else { return nil }
        if let prompt = conversation.messages
            .filter({ $0.role == .user })
            .sorted(by: { $0.createdAt > $1.createdAt })
            .first?
            .content
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !prompt.isEmpty {
            return prompt
        }
        let title = conversation.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if title.isEmpty || title == LaunchConversationSelection.safeStartTitle { return nil }
        if isGenericProjectName(title) { return nil }
        return title
    }

    private static func isGenericProjectName(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        if lower.isEmpty { return true }
        if lower == ProjectBootstrap.defaultProjectName.lowercased() { return true }
        if lower == "new project" || lower == "untitled project" { return true }
        if lower.range(of: #"^project\s+\d+$"#, options: .regularExpression) != nil { return true }
        if lower.range(of: #"^mission\s+draft\s+\d+$"#, options: .regularExpression) != nil { return true }
        if lower.range(of: #"^build\s+space\s+\d+$"#, options: .regularExpression) != nil { return true }
        return false
    }

    private static func bestNamingSource(prompt: String, mission: String) -> String {
        if !isGenericMission(mission) { return mission }
        return prompt
    }

    private static func isGenericMission(_ mission: String) -> Bool {
        let lower = mission.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if lower.isEmpty { return true }
        return lower == "build and verify useful work in novaforge." ||
            lower == "plan, build, and verify one focused outcome." ||
            lower == "send the first project request."
    }

    private static func isContinuationEnvelope(_ lower: String) -> Bool {
        lower.contains("novaforge project continuation") ||
            lower.contains("continue the active project")
    }

    private static func preferredName(from lower: String, source: String) -> String {
        if lower.contains("project os") && lower.contains("execution loop") {
            return "Project OS Execution Loop"
        }
        if lower.contains("autonomous") && lower.contains("builder") {
            return "Autonomous Builder Loop"
        }
        if lower.contains("agent") && lower.contains("proof") {
            return "Agent Proof Loop"
        }
        if lower.contains("project os") {
            return "Project OS"
        }
        if lower.contains("mission control") && lower.contains("project") {
            return "Mission Control"
        }
        if lower.contains("liquid glass") && lower.contains("project") {
            return "Liquid Glass Project Menu"
        }
        if lower.contains("slither") {
            return "Slither Game"
        }
        if lower.contains("snake") {
            return "Snake Game"
        }
        if lower.contains("game") {
            return "Game Build"
        }
        if lower.contains("dashboard") {
            return "Dashboard Build"
        }
        if lower.contains("landing page") || lower.contains("website") || lower.contains("web page") {
            return "Website Build"
        }
        if lower.contains("app") {
            return "App Build"
        }

        let words = source
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { word in
                word.count > 2 && !stopWords.contains(word) && Int(word) == nil
            }
            .prefix(4)
        let title = words.map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
        return title.isEmpty ? "Project Build" : title
    }

    private static func preferredMission(from prompt: String, currentMission: String, name: String) -> String {
        if !isGenericMission(currentMission) { return currentMission }
        let compactPrompt = prompt
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if compactPrompt.count > 24, !isContinuationEnvelope(compactPrompt.lowercased()) {
            let end = compactPrompt.index(compactPrompt.startIndex, offsetBy: min(compactPrompt.count, 140))
            return String(compactPrompt[..<end])
        }
        return "Build and verify \(name.lowercased())."
    }

    private static func uniqueProjectName(_ name: String, existingProjectNames: Set<String>) -> String {
        let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = cleaned.isEmpty ? "Project Build" : cleaned
        let existing = Set(existingProjectNames.map { $0.lowercased() })
        guard existing.contains(base.lowercased()) else { return base }
        for index in 2...99 {
            let candidate = "\(base) \(index)"
            if !existing.contains(candidate.lowercased()) { return candidate }
        }
        return "\(base) \(UUID().uuidString.prefix(4))"
    }

    private static let stopWords: Set<String> = [
        "the", "and", "for", "with", "that", "this", "from", "into", "make",
        "build", "create", "continue", "project", "please", "should", "would",
        "your", "nova", "novaforge", "active", "latest", "next", "step"
    ]
}

enum ProjectContinuationInstructionBuilder {
    static func makeInstruction(
        project: Project,
        summary: ProjectMissionSummary,
        intent: ProjectCommandIntent = .continueMission,
        operatorNote: String = ""
    ) -> String {
        var lines = [
            "NovaForge Project Continuation",
            "Continue the active project as an agent run. Do not merely restate this brief or ask the user to paste it again.",
            "Project: \(project.name)",
            "Mission: \(summary.missionText)",
            "Evidence totals: \(summary.toolRunCount) tool run(s), \(summary.terminalCommandCount) command(s), \(summary.artifactCount) artifact(s), \(summary.fileChangeCount) file change(s), \(summary.failureCount) issue(s).",
            "Project command: \(intent.displayName)",
            "Command focus: \(intent.instructionFocus)"
        ]

        if let latestProof = summary.proofItems.first,
           !latestProof.title.localizedCaseInsensitiveContains("Project created") {
            lines.append("Latest proof: \(latestProof.title) — \(latestProof.detail)")
        }

        let blocker = summary.blocker.trimmingCharacters(in: .whitespacesAndNewlines)
        if !blocker.isEmpty {
            lines.append("Blocker: \(blocker)")
        }

        let note = operatorNote.trimmingCharacters(in: .whitespacesAndNewlines)
        if !note.isEmpty {
            lines.append("Operator note: \(note)")
        }

        lines.append("Latest timeline event: \(summary.lastEventTitle) — \(summary.lastEventDetail)")
        lines.append("Recommended next step: \(summary.nextStep)")
        lines.append("Mission OS Contract:")
        lines.append("Phase: \(summary.missionContract.phase.displayName)")
        lines.append("Readiness: \(summary.missionContract.readinessScore)/100 (\(summary.missionContract.gateSummary))")
        lines.append("Mission OS recommends: \(summary.missionContract.recommendedIntent.displayName)")
        lines.append("Operator directive: \(summary.missionContract.operatorDirective)")
        lines.append("Proof requirement: \(summary.missionContract.proofRequirement)")
        lines.append("Decision state: \(summary.missionContract.decisionLabel)")
        lines.append("Quality gates:")
        for gate in summary.missionContract.gates {
            lines.append("- \(gate.state.displayName): \(gate.title) — \(gate.detail)")
        }
        lines.append("Success criteria:")
        for criterion in summary.missionContract.successCriteria {
            lines.append("- \(criterion)")
        }
        lines.append("Intent Handling: follow the selected project command first, but override it if the evidence shows a more urgent blocker, approval, or verification gap.")
        lines.append("Fast Proof: for UI proof, prefer the existing fast screenshot/proof commands and reuse a fresh binary; run a full Xcode build only when source changes require it.")
        lines.append("Agent Plan: first state the concrete next action you are taking and why. Choose from the mission, proof, blocker, latest run, changed files, and workspace state.")
        lines.append("Agent Work: inspect files, edit code, run safe commands/checks, or ask one clarifying question only if the next action is genuinely ambiguous. Respect approval requirements for mutating tools.")
        lines.append("Agent Proof: finish with a concise status plus files changed, commands/checks run, artifacts created or previewed, and any remaining blocker or next step.")
        lines.append("If the project still has a generic name, decide a concise project name from the mission/request and state it in the response.")
        return lines.joined(separator: "\n")
    }
}

enum LaunchConversationSelection {
    static let persistedSelectionKey = "novaForgeSelectedConversationID"
    static let safeStartTitle = "NovaForge Ready"

    static func preferredConversation(
        from conversations: [Conversation],
        sessionID: UUID?,
        persistedIDString: String
    ) -> Conversation? {
        if let sessionID,
           let match = conversations.first(where: { $0.id == sessionID }) {
            return match
        }

        if let ready = conversations.first(where: { $0.title == safeStartTitle && !$0.hasUserMessages }) {
            return ready
        }

        if let persistedID = UUID(uuidString: persistedIDString),
           let persisted = conversations.first(where: { $0.id == persistedID }),
           isLaunchRestorable(persisted) {
            return persisted
        }

        return conversations.first
    }

    static func preferredConversation(
        from conversations: [Conversation],
        sessionID: UUID?,
        persistedIDString: String,
        project: Project?
    ) -> Conversation? {
        guard let project else {
            return preferredConversation(
                from: conversations,
                sessionID: sessionID,
                persistedIDString: persistedIDString
            )
        }
        let projectConversations = conversations.filter { $0.project?.id == project.id }
        return preferredConversation(
            from: projectConversations,
            sessionID: sessionID,
            persistedIDString: persistedIDString
        )
    }

    static func isLaunchRestorable(_ conversation: Conversation) -> Bool {
        guard conversation.hasUserMessages else { return false }
        guard let latest = conversation.messages.max(by: messageAscending) else { return false }

        // A launch restore should land on a settled chat. If the last persisted
        // item is a user prompt, tool output, or assistant tool request, the app
        // likely closed mid-run; start safe instead of showing a stuck old chat.
        guard latest.role == .assistant else { return false }
        if let toolCalls = latest.toolCalls, !toolCalls.isEmpty { return false }

        let trimmedContent = latest.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedContent.isEmpty else { return false }

        let lowercased = trimmedContent.lowercased()
        if lowercased.hasPrefix("i hit an error:") { return false }
        if lowercased.contains("tap retry") || lowercased.contains("provider setup needed") { return false }
        if lowercased.contains("run paused") || lowercased.contains("cancelled while waiting for approval") { return false }
        return true
    }

    private static func messageAscending(_ lhs: ChatMessage, _ rhs: ChatMessage) -> Bool {
        if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
        return lhs.id.uuidString < rhs.id.uuidString
    }
}

enum ChatProjectSeparation {
    static func visibleChatConversations(from conversations: [Conversation]) -> [Conversation] {
        let general = conversations.filter { $0.project == nil }
        return general.isEmpty ? conversations : general
    }

    static func preferredGeneralConversation(
        from conversations: [Conversation],
        selectedID: UUID?,
        persistedIDString: String
    ) -> Conversation? {
        let general = visibleChatConversations(from: conversations)
        if let ready = general.first(where: { $0.title == LaunchConversationSelection.safeStartTitle && !$0.hasUserMessages }) {
            return ready
        }
        if let selectedID,
           let selected = general.first(where: { $0.id == selectedID }) {
            return selected
        }
        if let persistedID = UUID(uuidString: persistedIDString),
           let persisted = general.first(where: { $0.id == persistedID }),
           LaunchConversationSelection.isLaunchRestorable(persisted) {
            return persisted
        }
        if let restorable = general.first(where: LaunchConversationSelection.isLaunchRestorable) {
            return restorable
        }
        return general.first
    }
}

enum PersistentLaunchRecovery {
    static func recoverInterruptedToolRuns(in context: ModelContext, now: Date = Date()) {
        let pending = ToolRunStatus.pendingApproval.rawValue
        let approved = ToolRunStatus.approved.rawValue
        let descriptor = FetchDescriptor<ToolRun>(
            predicate: #Predicate<ToolRun> { run in
                run.statusRawValue == pending || run.statusRawValue == approved
            }
        )

        guard let interruptedRuns = try? context.fetch(descriptor) else { return }
        for run in interruptedRuns {
            switch run.status {
            case .pendingApproval:
                run.status = .rejected
                run.output = PersistedPayloadBudget.compactToolRunOutput(recoveryOutput(
                    existingOutput: run.output,
                    message: "Recovered after app restart: NovaForge cancelled this stale approval before launch so the Runs view cannot stay pending forever. Re-run the request when ready."
                ))
                ProjectEventRecorder.record(
                    project: run.project,
                    kind: .toolRejected,
                    title: "Recovered stale approval",
                    detail: run.name,
                    severity: .warning,
                    sourceType: .toolRun,
                    sourceID: run.id,
                    context: context,
                    now: now
                )
            case .approved:
                run.status = .failed
                run.output = PersistedPayloadBudget.compactToolRunOutput(recoveryOutput(
                    existingOutput: run.output,
                    message: "Recovered after app restart: this approved tool did not finish before the app closed, so NovaForge marked it failed instead of leaving it in progress."
                ))
                ProjectEventRecorder.record(
                    project: run.project,
                    kind: .toolFailed,
                    title: "Recovered unfinished tool",
                    detail: run.name,
                    severity: .failure,
                    sourceType: .toolRun,
                    sourceID: run.id,
                    context: context,
                    now: now
                )
            default:
                continue
            }
            run.completedAt = now
        }

        recoverInterruptedProjectOSRuns(in: context, now: now)
        recoverInterruptedAutoContinue(in: context, now: now)
    }

    private static func recoverInterruptedProjectOSRuns(in context: ModelContext, now: Date) {
        let planning = ProjectOSRunStatus.planning.rawValue
        let running = ProjectOSRunStatus.running.rawValue
        let descriptor = FetchDescriptor<ProjectOSRun>(
            predicate: #Predicate<ProjectOSRun> { run in
                run.statusRawValue == planning || run.statusRawValue == running
            }
        )
        guard let runs = try? context.fetch(descriptor) else { return }
        for run in runs {
            run.status = .stopped
            run.resumeState = "Stopped after relaunch. Start or retry the mission from ProjectOS when ready."
            run.currentAction = "Run stopped after relaunch"
            run.updatedAt = now
            run.completedAt = now
            run.applyIntent(ProjectOSIntentDeriver.makeRecoveryIntent(run: run, now: now))
            for step in run.steps where !step.status.isTerminal {
                step.status = .stopped
                step.resultSummary = run.resumeState
                step.updatedAt = now
                step.completedAt = now
            }
        }
    }

    private static func recoverInterruptedAutoContinue(in context: ModelContext, now: Date) {
        let countdown = ProjectAutoContinueState.countdown.rawValue
        let descriptor = FetchDescriptor<Project>(
            predicate: #Predicate<Project> { project in
                project.autoContinueStateRawValue == countdown
            }
        )
        guard let projects = try? context.fetch(descriptor) else { return }
        for project in projects {
            project.autoContinuePaused = true
            project.autoContinueState = .paused
            project.autoContinueDecision = "Paused after relaunch before starting the next automatic step."
            project.autoContinueUpdatedAt = now
            ProjectEventRecorder.record(
                project: project,
                kind: .autoContinuePaused,
                title: "Auto-continue paused after relaunch",
                detail: project.autoContinueDecision ?? "",
                severity: .warning,
                sourceType: .system,
                context: context,
                now: now
            )
        }
    }

    private static func recoveryOutput(existingOutput: String, message: String) -> String {
        let trimmed = existingOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return message }
        return "\(trimmed)\n\n\(message)"
    }
}

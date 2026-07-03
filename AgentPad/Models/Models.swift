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

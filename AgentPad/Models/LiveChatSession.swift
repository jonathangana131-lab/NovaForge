import Foundation

/// Pure presentation vocabulary for the Forge live run experience.
///
/// These types intentionally avoid SwiftUI and persistence so the UI can render a
/// coherent command-center state without mutating `AgentRuntime` or SwiftData.
enum LiveChatSessionPhase: Equatable, Sendable {
    case idle
    case composing
    case connecting(provider: String)
    case thinking(summary: String)
    case streaming(summary: String)
    case usingTool(name: String, target: String?)
    case waitingForApproval(summary: String)
    case verifying(summary: String)
    case completed(summary: String)
    case failed(summary: String, recovery: LiveChatRecoveryAction)
    case cancelled
}

enum LiveChatActionKind: String, Equatable, Sendable {
    case addInstruction
    case queueFollowUp
    case stop
    case approve
    case reject
    case retry
    case switchModel
    case copyDetails
    case continueFromResult
    case openArtifact
    case openProof
}

struct LiveChatAction: Identifiable, Equatable, Sendable {
    var kind: LiveChatActionKind
    var title: String
    var symbolName: String
    var isPrimary: Bool

    var id: String { kind.rawValue }
}

struct LiveChatRecoveryAction: Equatable, Sendable {
    var title: String
    var detail: String?
    var primaryAction: LiveChatActionKind
    var secondaryActions: [LiveChatActionKind]

    static let standardFailure = LiveChatRecoveryAction(
        title: "Recover the run",
        detail: "Retry, switch models, or copy details for debugging.",
        primaryAction: .retry,
        secondaryActions: [.switchModel, .copyDetails]
    )
}

struct LiveChatBadge: Identifiable, Equatable, Sendable {
    enum Tone: String, Equatable, Sendable {
        case neutral
        case active
        case waiting
        case success
        case danger
    }

    var id: String
    var title: String
    var symbolName: String
    var tone: Tone
}

struct LiveChatProgressCard: Identifiable, Equatable, Sendable {
    enum State: String, Equatable, Sendable {
        case pending
        case active
        case waiting
        case done
        case failed
    }

    var id: String
    var title: String
    var detail: String?
    var symbolName: String
    var state: State
}

struct LiveChatArtifactHandoff: Identifiable, Equatable, Sendable {
    var id: String
    var title: String
    var subtitle: String
    var path: String
    var typeName: String
    var primaryActionTitle: String
}

struct LiveChatStreamSnapshot: Equatable, Sendable {
    var displayText: String
    var characterCount: Int
    var revealBacklog: Int
    var isShowingTail: Bool

    var isEmpty: Bool { displayText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    static let empty = LiveChatStreamSnapshot(
        displayText: "",
        characterCount: 0,
        revealBacklog: 0,
        isShowingTail: false
    )
}

struct LiveChatSessionInput: Equatable, Sendable {
    var runState: AgentRunState
    var isWorking: Bool
    var activityTitle: String
    var activityDetail: String?
    var activeToolName: String?
    var activeToolDetail: String?
    var pendingTool: ToolRequest?
    var traceEvents: [AgentTraceEvent]
    var plannedProgressSteps: [WorkspaceProgressStep]
    var currentArtifacts: [WorkspaceArtifact]
    var liveStream: LiveChatStreamSnapshot
    var liveResponseDocument: AIStreamDocument
    var usesAIResponseStage: Bool
    var queuedPromptCount: Int
    var providerDisplayName: String
    var modelDisplayName: String?

    init(
        runState: AgentRunState = .idle,
        isWorking: Bool = false,
        activityTitle: String = "Ready",
        activityDetail: String? = nil,
        activeToolName: String? = nil,
        activeToolDetail: String? = nil,
        pendingTool: ToolRequest? = nil,
        traceEvents: [AgentTraceEvent] = [],
        plannedProgressSteps: [WorkspaceProgressStep] = [],
        currentArtifacts: [WorkspaceArtifact] = [],
        liveStream: LiveChatStreamSnapshot = .empty,
        liveResponseDocument: AIStreamDocument = .empty,
        usesAIResponseStage: Bool = false,
        queuedPromptCount: Int = 0,
        providerDisplayName: String = "Local",
        modelDisplayName: String? = nil
    ) {
        self.runState = runState
        self.isWorking = isWorking
        self.activityTitle = activityTitle
        self.activityDetail = activityDetail
        self.activeToolName = activeToolName
        self.activeToolDetail = activeToolDetail
        self.pendingTool = pendingTool
        self.traceEvents = traceEvents
        self.plannedProgressSteps = plannedProgressSteps
        self.currentArtifacts = currentArtifacts
        self.liveStream = liveStream
        self.liveResponseDocument = liveResponseDocument
        self.usesAIResponseStage = usesAIResponseStage
        self.queuedPromptCount = queuedPromptCount
        self.providerDisplayName = providerDisplayName
        self.modelDisplayName = modelDisplayName
    }
}

struct LiveChatSessionViewState: Equatable, Sendable {
    var phase: LiveChatSessionPhase
    var primaryLine: String
    var secondaryLine: String?
    var badges: [LiveChatBadge]
    var actions: [LiveChatAction]
    var progressCards: [LiveChatProgressCard]
    var artifactHandoffs: [LiveChatArtifactHandoff]
    var liveResponseDocument: AIStreamDocument = .empty
    var usesAIResponseStage: Bool = false
    var shouldShowLiveRunCard: Bool
    var shouldShowInlineProgress: Bool
    var shouldReserveComposerQueue: Bool

    static let idle = LiveChatSessionViewState(
        phase: .idle,
        primaryLine: "Ready",
        secondaryLine: "Start a prompt when you’re ready.",
        badges: [],
        actions: [],
        progressCards: [],
        artifactHandoffs: [],
        shouldShowLiveRunCard: false,
        shouldShowInlineProgress: false,
        shouldReserveComposerQueue: false
    )
}

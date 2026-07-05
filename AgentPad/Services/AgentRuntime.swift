import Foundation
import Combine
import Observation
import SwiftData
import UIKit

enum AgentTraceStatus: String, Hashable {
    case queued
    case thinking
    case planning
    case tool
    case approval
    case executing
    case paused
    case success
    case failed
}

enum AgentRunState: Equatable, Sendable {
    case idle
    case running
    case waitingForApproval
    case completed
    case cancelled
    case failed(String)
}

enum AgentRunOrigin: String, Equatable, Sendable {
    case manual
    case autoContinued
}

enum AgentRuntimeError: LocalizedError {
    case tooManyToolRounds
    case localInferenceTimedOut(String)

    var errorDescription: String? {
        switch self {
        case .tooManyToolRounds:
            "The run paused at NovaForge's tool-call safety limit. Continue the run to resume from the saved progress."
        case .localInferenceTimedOut(let model):
            "\(model) did not finish in the local safety window. NovaForge stopped the run so the app stays responsive. First launch after installing or downloading a model can be slow on iPhone 12; wait a moment, then tap Retry."
        }
    }
}

private final class LocalInferenceContinuationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var didResume = false

    func resume(
        _ continuation: CheckedContinuation<ProviderResponse, Error>,
        with result: Result<ProviderResponse, Error>
    ) {
        lock.lock()
        guard !didResume else {
            lock.unlock()
            return
        }
        didResume = true
        lock.unlock()

        continuation.resume(with: result)
    }
}

struct AgentTraceEvent: Identifiable, Hashable {
    let id = UUID()
    var title: String
    var detail: String
    var status: AgentTraceStatus
    var createdAt = Date()
}

@MainActor
final class LiveStreamBuffer: ObservableObject {
    private let minimumDisplayInterval: Duration = .milliseconds(80)
    private let minimumInitialDisplayCharacters = 1
    private let maximumPendingCharacters = 260
    private let maximumDisplayedCharacters = 900
    @Published private var frame = LiveStreamFrame()
    @ObservationIgnored private var visibleText = ""
    @ObservationIgnored private var pendingText = ""
    @ObservationIgnored private var flushTask: Task<Void, Never>?
    @ObservationIgnored private var lastDisplayUpdate = ContinuousClock.now
    @Published private(set) var responseID = UUID()
    @Published private(set) var handoffMessageID: UUID?

    var displayText: String {
        guard frame.displayText.count > maximumDisplayedCharacters else {
            return frame.displayText
        }
        return "...\n" + String(frame.displayText.suffix(maximumDisplayedCharacters))
    }
    var characterCount: Int { frame.characterCount }
    var revision: Int { frame.revision }
    var isEmpty: Bool { frame.characterCount == 0 }
    var isHandoffActive: Bool { handoffMessageID != nil && !isEmpty }
    var isShowingTail: Bool { frame.displayText.count > maximumDisplayedCharacters }

    func reset() {
        flushTask?.cancel()
        flushTask = nil
        pendingText = ""
        visibleText = ""
        responseID = UUID()
        handoffMessageID = nil
        frame = LiveStreamFrame()
        lastDisplayUpdate = .now
    }

    func append(_ delta: String) {
        guard !delta.isEmpty else { return }
        pendingText += delta

        if visibleText.isEmpty && pendingText.count < minimumInitialDisplayCharacters {
            scheduleFlush()
        } else if visibleText.isEmpty || pendingText.count >= maximumPendingCharacters {
            flushPending()
        } else {
            scheduleFlush()
        }
    }

    func flushPending() {
        flushTask?.cancel()
        flushTask = nil
        guard !pendingText.isEmpty else { return }

        let delta = pendingText
        pendingText.removeAll(keepingCapacity: true)
        let updatedCharacterCount = frame.characterCount + delta.count
        visibleText += delta
        frame = LiveStreamFrame(
            displayText: visibleText,
            characterCount: updatedCharacterCount,
            revision: frame.revision + 1
        )
        AgentPerformance.event("Live Stream Flush")
        AgentPerformance.value("Live Stream Flush Characters", Double(delta.count))
        AgentPerformance.value("Live Stream Visible Characters", Double(visibleText.count))
        lastDisplayUpdate = .now
    }

    func finishHandoff(to messageID: UUID) {
        flushPending()
        flushTask?.cancel()
        flushTask = nil
        responseID = messageID
        handoffMessageID = messageID
        frame = LiveStreamFrame(
            displayText: visibleText,
            characterCount: visibleText.count,
            revision: frame.revision + 1
        )
        lastDisplayUpdate = .now
    }

    func clearHandoffIfRendered(messageID: UUID) {
        guard handoffMessageID == messageID else { return }
        reset()
    }

    private func scheduleFlush() {
        let elapsed = lastDisplayUpdate.duration(to: .now)
        if elapsed >= minimumDisplayInterval {
            flushPending()
            return
        }

        guard flushTask == nil else { return }
        let delay = minimumDisplayInterval - elapsed
        flushTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            self?.flushPending()
        }
    }

}

fileprivate struct LiveStreamFrame: Equatable {
    var displayText = ""
    var characterCount = 0
    var revision = 0
}

@MainActor
private final class LocalBenchmarkProbe {
    var firstBatchAt: Date?
    var characters = 0
}

@MainActor
@Observable
final class AgentRuntime {
    var runState: AgentRunState = .idle
    var isWorking = false {
        didSet {
            guard oldValue != isWorking else { return }
            if isWorking {
                NovaHaptics.runStarted()
                RunActivityController.shared.runStarted(
                    projectName: workspace.workspaceName,
                    statusLine: activityTitle == "Ready" ? "Agent run started" : activityTitle
                )
            } else {
                let succeeded = lastError == nil && !wasInterrupted
                if succeeded { NovaHaptics.runSucceeded() } else { NovaHaptics.runFailed() }
                RunActivityController.shared.runEnded(
                    statusLine: lastError ?? activityTitle,
                    success: succeeded
                )
            }
        }
    }
    @ObservationIgnored var liveStream = LiveStreamBuffer()
    var pendingTool: ToolRequest? {
        didSet {
            if pendingTool != nil, oldValue == nil {
                NovaHaptics.approvalNeeded()
            }
        }
    }
    var lastError: String?
    var lastFailedPrompt: String?
    var activityTitle = "Ready"
    var activityDetail = "Waiting for your next request."
    var activeToolName: String?
    var activeToolDetail = ""
    var traceEvents: [AgentTraceEvent] = [] {
        didSet {
            // Maintain cheap derived flags so view bodies can depend on
            // "are there traces" / "was there a success" without observing the
            // growing array itself (which would re-render whole surfaces on
            // every appended event). These flip at most twice per run.
            let hasEvents = !traceEvents.isEmpty
            if hasTraceEvents != hasEvents { hasTraceEvents = hasEvents }
            let hasSuccess = hasEvents && traceEvents.contains { $0.status == .success }
            if hasSuccessfulTraceEvent != hasSuccess { hasSuccessfulTraceEvent = hasSuccess }
        }
    }
    private(set) var hasTraceEvents = false
    private(set) var hasSuccessfulTraceEvent = false
    var plannedProgressSteps: [WorkspaceProgressStep] = []
    var currentArtifacts: [WorkspaceArtifact] = []
    var queuedPromptCount = 0
    var outgoingProviderRoleLog = ""
    var lastRunDuration: TimeInterval?
    var wasInterrupted = false
    private(set) var queuedFollowUpMessageIDs: Set<UUID> = []
    let localModels = LocalModelManager()
    /// Transient in-app feedback queue (saves, copies, recoverable failures).
    /// Surfaces through AgentToastView so user-facing operations no longer fail
    /// silently behind empty catch blocks.
    var toasts: [AgentToast] = []

    var workspace: SandboxWorkspace
    private let keychain = KeychainStore()
    private let localModelClient = LocalModelClient()
    private let maxQueuedPrompts = 3
    private let maxQueuedPromptCharacters = 4_000
    private let maxToolRoundCount = 96
    private var queuedPrompts: [QueuedPrompt] = []
    private var currentTask: Task<Void, Never>?
    private var activeRunID: UUID?
    private var stopRequested = false
    private var runStartedAt: Date?
    private var currentPrompt: String?
    private var lastRunConversation: Conversation?
    private(set) var activeConversationID: UUID?
    private(set) var activeConversationTitle: String?
    private var pendingApprovalRun: ToolRun?
    private var activeLocalModelID: String?
    private var cachedWorkspaceSummary: (signature: String, provider: AIProvider, text: String)?
    #if DEBUG || targetEnvironment(simulator)
    private var didInjectRecoverableFailureFixture = false
    private var debugCompactedSaveOverride: ((ModelContext) throws -> Void)?
    private var debugProviderResponses: [ProviderResponse] = []
    private var debugProviderFailure: Error?
    private var debugProviderCredentialOverride = false
    #endif

    private struct QueuedPrompt: Identifiable {
        let id = UUID()
        let text: String
        let conversation: Conversation
        let visibleMessageID: UUID?
        let createdAt = Date()
    }

    init(workspace: SandboxWorkspace = SandboxWorkspace()) {
        self.workspace = workspace
    }

    private func setLastRunConversation(_ conversation: Conversation?) {
        lastRunConversation = conversation
        activeConversationID = conversation?.id
        let title = conversation?.title.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        activeConversationTitle = title.isEmpty ? nil : title
    }

    #if DEBUG || targetEnvironment(simulator)
    var debugHasTrackedTask: Bool { currentTask != nil }

    func debugInstallPendingApproval(request: ToolRequest, run: ToolRun) {
        pendingTool = request
        pendingApprovalRun = run
        isWorking = false
        runState = .waitingForApproval
        setActiveTool(request, title: "Approval needed")
        pushTrace("Approval needed", detail: request.argumentsJSON, status: .approval)
    }

    func debugInstallCompletedArtifact(_ artifact: WorkspaceArtifact) {
        pendingTool = nil
        pendingApprovalRun = nil
        isWorking = false
        runState = .completed
        stopRequested = false
        wasInterrupted = false
        lastError = nil
        lastFailedPrompt = nil
        lastRunDuration = 1.4
        activeToolName = nil
        activeToolDetail = ""
        currentArtifacts = [artifact]
        traceEvents = []
        liveStream.reset()
        setActivity("Artifact ready", detail: artifact.title)
        pushTrace("Wrote artifact", detail: artifact.path, status: .success)
        pushTrace("Run complete", detail: "Deterministic artifact handoff fixture.", status: .success)
    }

    func debugInstallCompletedLocalAgentBoundaryArtifact(_ artifact: WorkspaceArtifact) {
        pendingTool = nil
        pendingApprovalRun = nil
        isWorking = false
        runState = .completed
        stopRequested = false
        wasInterrupted = false
        lastError = nil
        lastFailedPrompt = nil
        lastRunDuration = 1.8
        activeToolName = nil
        activeToolDetail = ""
        currentArtifacts = [artifact]
        traceEvents = [
            AgentTraceEvent(title: "File Info", detail: "Checked \(artifact.path) metadata.", status: .success),
            AgentTraceEvent(title: "Validate HTML", detail: "HTML validation passed for the playable game.", status: .success),
            AgentTraceEvent(title: "Write File", detail: "Wrote \(artifact.path).", status: .success)
        ]
        liveStream.reset()
        setActivity("Artifact ready", detail: artifact.title)
    }

    func simulateRecoverableFailure(failedPrompt: String = "Continue the interrupted request.") {
        guard !didInjectRecoverableFailureFixture else { return }
        didInjectRecoverableFailureFixture = true
        isWorking = false
        runState = .failed("The network connection was lost. Reconnect, then tap Retry.")
        lastError = "The network connection was lost. Reconnect, then tap Retry."
        lastFailedPrompt = failedPrompt
        setActivity("Something needs attention", detail: lastError ?? "Network unavailable.")
    }

    func debugQueueFollowUp(_ prompt: String, conversation: Conversation) {
        _ = queueFollowUp(prompt, conversation: conversation)
    }

    func debugInstallCompactedSaveOverride(_ override: ((ModelContext) throws -> Void)?) {
        debugCompactedSaveOverride = override
    }

    func debugInstallProviderResponses(_ responses: [ProviderResponse]) {
        debugProviderCredentialOverride = true
        debugProviderResponses = responses
    }

    func debugInstallProviderFailure(_ error: Error) {
        debugProviderCredentialOverride = true
        debugProviderFailure = error
    }

    func debugSimulateActiveStatusStripRun(conversation: Conversation? = nil) {
        if isWorking {
            if pendingTool == nil,
               activeConversationID == nil,
               let conversation {
                setLastRunConversation(conversation)
            }
            return
        }
        guard pendingTool == nil else { return }
        isWorking = true
        runState = .running
        stopRequested = false
        wasInterrupted = false
        setLastRunConversation(conversation)
        liveStream.reset()
        traceEvents = [
            AgentTraceEvent(title: "Running command/check", detail: "Verifying shared workspace controls.", status: .executing),
            AgentTraceEvent(title: "Inspecting files/evidence", detail: "Reviewing recent project state before proof.", status: .thinking),
            AgentTraceEvent(title: "Reading project state", detail: "Mission, timeline, files, and proof loaded.", status: .planning)
        ]
        activeToolName = "release check"
        activeToolDetail = "Verifying shared workspace controls."
        setActivity("Release check running", detail: "Workspace controls should remain easy to pause or review from Project.")
        pushTrace("Release check started", detail: "Debug fixture keeps the shared status strip active without network work.", status: .thinking)
        _ = beginRunIdentity()
    }

    func simulateStreamingStress() {
        guard !isWorking, pendingTool == nil else { return }

        isWorking = true
        runState = .running
        stopRequested = false
        wasInterrupted = false
        liveStream.reset()
        traceEvents = []
        updateActiveTool(name: "stream renderer", detail: "Preparing batch 0 of 600")
        setActivity("Streaming stress test", detail: "Rendering a deterministic long response.")
        pushTrace("Streaming fixture started", detail: "600 bounded UI batches.", status: .thinking)

        let runID = beginRunIdentity()
        currentTask = Task { [weak self] in
            guard let self else { return }
            defer { self.clearCurrentTaskIfActive(runID) }
            for index in 1...600 {
                guard !Task.isCancelled, !self.stopRequested else { return }
                if index == 1 || index % 60 == 0 {
                    self.updateActiveTool(name: "stream renderer", detail: "Rendering batch \(index) of 600")
                }
                self.liveStream.append(
                    "Batch \(index): NovaForge keeps network parsing off the main actor and updates only the live response island. "
                )
                if index == 1 || index % 120 == 0 {
                    self.pushTrace("Stream batch \(index)", detail: "Live response and progress trace grew without losing the bottom pin.", status: .thinking)
                }
                try? await Task.sleep(for: .milliseconds(220))
            }

            guard !Task.isCancelled, !self.stopRequested else { return }
            self.liveStream.flushPending()
            self.setActivity("Streaming fixture complete", detail: "The full bounded stream rendered successfully.")
            self.pushTrace("Streaming fixture complete", detail: "600 batches delivered.", status: .success)
            self.runState = .completed
            self.isWorking = false
            self.clearActiveTool()
        }
    }

    func debugSimulateDelayedCompletionForActiveRun(delayMilliseconds: UInt64 = 120) {
        guard !isWorking, pendingTool == nil else { return }
        isWorking = true
        runState = .running
        stopRequested = false
        wasInterrupted = false
        setActivity("Delayed completion fixture", detail: "A stale async completion will try to finish this run.")
        pushTrace("Delayed completion started", detail: "Debug fixture for active-run identity gating.", status: .thinking)

        let runID = beginRunIdentity()
        currentTask = Task { [weak self] in
            guard let self else { return }
            defer { self.clearCurrentTaskIfActive(runID) }
            try? await Task.sleep(for: .milliseconds(delayMilliseconds))
            guard self.isActiveRun(runID) else { return }
            self.setActivity("Stale completion applied", detail: "This should only appear for the original active run.")
            self.pushTrace("Delayed completion applied", detail: "Original run was still active.", status: .success)
            self.runState = .completed
            self.isWorking = false
        }
    }
    #endif

    func switchWorkspace(to name: String) {
        if workspace.workspaceName != name {
            invalidateWorkspaceSummaryCache()
            self.workspace = SandboxWorkspace(name: name)
            ensureSeedWorkspace()
        }
    }

    func ensureSeedWorkspace() {
        let readme = "README.md"
        if (try? workspace.read(readme)) == nil {
            try? workspace.write(readme, contents: """
            # NovaForge Workspace

            This folder lives inside the iOS app sandbox. Ask NovaForge to create notes, edit files, search text, or run safe native commands.
            """)
            invalidateWorkspaceSummaryCache()
        }
    }

    func apiKey(for provider: AIProvider) -> String {
        (try? keychain.read(provider.apiKeyAccount)) ?? ""
    }

    func saveAPIKey(_ value: String, for provider: AIProvider) throws {
        if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            try keychain.delete(provider.apiKeyAccount)
        } else {
            try keychain.save(value.trimmingCharacters(in: .whitespacesAndNewlines), account: provider.apiKeyAccount)
        }
    }

    /// Runs a short fixed-prompt generation against the selected local model
    /// and measures wall-clock throughput. Generation length is bounded by
    /// the variant's own maxNewTokens cap, so runs are quick and comparable.
    func runLocalModelBenchmark(settings: AgentSettings) async -> Result<LocalModelBenchmarkResult, Error> {
        let variant = LocalModelCatalog.variant(for: settings.modelID) ?? LocalModelCatalog.defaultVariant
        guard localModels.isDownloaded else {
            return .failure(LocalModelRuntimeError.modelNotDownloaded(variant.displayName))
        }

        let probe = LocalBenchmarkProbe()
        let started = Date()

        let prompt = ProviderMessageInput(
            id: UUID(),
            role: .user,
            content: "Write a two-line poem about forging stars. Reply with only the poem.",
            createdAt: started,
            toolCallID: nil,
            toolCalls: []
        )

        do {
            _ = try await localModelClient.streamingResponse(
                messages: [prompt],
                model: variant.id,
                temperature: 0.3,
                customSystemPrompt: "You are a concise poet.",
                workspaceSummary: "",
                onContentBatch: { chunk in
                    if probe.firstBatchAt == nil { probe.firstBatchAt = Date() }
                    probe.characters += chunk.count
                }
            )
        } catch {
            return .failure(error)
        }

        let finished = Date()
        let first = probe.firstBatchAt ?? finished
        return .success(LocalModelBenchmarkResult(
            modelName: variant.shortName,
            timeToFirstToken: first.timeIntervalSince(started),
            totalDuration: finished.timeIntervalSince(started),
            generatedCharacters: probe.characters
        ))
    }

    func testAPIKey(settings: AgentSettings) async -> Result<Void, Error> {
        if settings.provider == .local {
            do {
                let variant = LocalModelCatalog.variant(for: settings.modelID) ?? LocalModelCatalog.defaultVariant
                _ = try localModels.localFileURL(for: variant)
                return .success(())
            } catch {
                return .failure(error)
            }
        }

        let providerConfiguration = ProviderConfiguration(
            provider: settings.provider,
            modelID: settings.modelID,
            apiKey: apiKey(for: settings.provider),
            customChatCompletionsURL: settings.resolvedCustomChatCompletionsURL
        )
        do {
            try await AIProviderClient(configuration: providerConfiguration).testConnection(model: settings.modelID)
            return .success(())
        } catch {
            return .failure(error)
        }
    }

    func testConnection(
        provider: AIProvider,
        modelID: String,
        customChatCompletionsURL: String
    ) async -> Result<Void, Error> {
        if provider == .local {
            do {
                let variant = LocalModelCatalog.variant(for: modelID) ?? LocalModelCatalog.defaultVariant
                _ = try localModels.localFileURL(for: variant)
                return .success(())
            } catch {
                return .failure(error)
            }
        }

        let providerConfiguration = ProviderConfiguration(
            provider: provider,
            modelID: modelID,
            apiKey: apiKey(for: provider),
            customChatCompletionsURL: customChatCompletionsURL
        )
        do {
            try await AIProviderClient(configuration: providerConfiguration).testConnection(model: modelID)
            return .success(())
        } catch {
            return .failure(error)
        }
    }

    func hasUsableProviderCredential(settings: AgentSettings) -> Bool {
        if settings.provider == .local { return true }
        #if DEBUG || targetEnvironment(simulator)
        if debugProviderCredentialOverride || !debugProviderResponses.isEmpty || debugProviderFailure != nil { return true }
        #endif
        return !apiKey(for: settings.provider).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func send(
        prompt: String,
        conversation: Conversation,
        settings: AgentSettings,
        context: ModelContext,
        project: Project? = nil,
        origin: AgentRunOrigin = .manual,
        visiblePrompt: String? = nil
    ) {
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if isWorking || pendingTool != nil {
            if let activeConversationID, activeConversationID != conversation.id {
                let title = activeConversationTitle?.isEmpty == false ? activeConversationTitle! : "another chat"
                presentToast("A response is already running in \(title). Open that chat to queue a follow-up.", tone: .info)
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                return
            }
            if queueFollowUp(prompt, conversation: conversation, context: context, project: project ?? conversation.project) {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            }
            return
        }

        startPrompt(prompt, conversation: conversation, settings: settings, context: context, project: project, origin: origin, visiblePrompt: visiblePrompt)
    }

    func retryLastPrompt(conversation: Conversation, settings: AgentSettings, context: ModelContext, project: Project? = nil) {
        guard let lastFailedPrompt else { return }
        let targetConversation = lastRunConversation ?? conversation
        clearCurrentRunState(keepLastFailure: false)
        send(prompt: lastFailedPrompt, conversation: targetConversation, settings: settings, context: context, project: project)
    }

    func continueAfterInterruption(conversation: Conversation, settings: AgentSettings, context: ModelContext, project: Project? = nil) {
        let targetConversation = lastRunConversation ?? conversation
        let lastUserRequest = lastFailedPrompt
            ?? latestUserPrompt(in: targetConversation)
            ?? "Continue."
        clearCurrentRunState(keepLastFailure: false)
        send(
            prompt: "Continue from where the previous run stopped. Do not restart completed work unless needed. Original request: \(lastUserRequest)",
            conversation: targetConversation,
            settings: settings,
            context: context,
            project: project
        )
    }

    func stopGenerating(context: ModelContext? = nil) {
        stopRequested = true
        currentTask?.cancel()
        currentTask = nil
        activeRunID = nil
        stopActiveLocalModel()
        if let pendingApprovalRun {
            let pendingRequest = pendingTool
            let previousOutput = pendingApprovalRun.output
            let previousStatus = pendingApprovalRun.status
            let previousCompletedAt = pendingApprovalRun.completedAt
            pendingApprovalRun.output = "Cancelled while waiting for approval."
            pendingApprovalRun.status = .rejected
            pendingApprovalRun.completedAt = Date()
            if let context {
                do {
                    try saveCompacted(context)
                } catch {
                    pendingApprovalRun.output = previousOutput
                    pendingApprovalRun.status = previousStatus
                    pendingApprovalRun.completedAt = previousCompletedAt
                    pendingTool = pendingRequest
                    self.pendingApprovalRun = pendingApprovalRun
                    stopRequested = false
                    isWorking = false
                    runState = .waitingForApproval
                    let message = friendlyError(error)
                    lastError = message
                    if let pendingRequest {
                        setActiveTool(pendingRequest, title: "Cancellation Not Saved")
                    } else {
                        setActivity("Cancellation Not Saved", detail: "NovaForge kept the approval open because the cancellation could not be saved. Try again after storage recovers.")
                    }
                    pushTrace("Cancellation not saved", detail: message, status: .failed)
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    return
                }
            }
            if let context {
                ProjectEventRecorder.record(
                    project: pendingApprovalRun.project ?? lastRunConversation?.project,
                    kind: .toolRejected,
                    title: "Approval cancelled",
                    detail: pendingRequest?.name ?? "Pending tool",
                    severity: .warning,
                    sourceType: .toolRun,
                    sourceID: pendingApprovalRun.id,
                    context: context
                )
            }
        }
        pendingTool = nil
        pendingApprovalRun = nil
        discardQueuedPrompts()
        isWorking = false
        runState = .cancelled
        wasInterrupted = true
        if let currentPrompt {
            lastFailedPrompt = currentPrompt
        }
        activeToolName = nil
        activeToolDetail = ""
        liveStream.reset()
        setActivity("Paused", detail: "Run paused. You can continue, retry, or inspect progress.")
        pushTrace("Paused by user", detail: "The active run was paused before completion.", status: .paused)
        if let context {
            ProjectEventRecorder.record(
                project: lastRunConversation?.project,
                kind: .runPaused,
                title: "Run paused",
                detail: currentPrompt ?? "The active run was paused before completion.",
                severity: .warning,
                sourceType: .conversation,
                sourceID: lastRunConversation?.id,
                context: context
            )
            saveCompactedIfPossible(context)
        }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    // MARK: - Transient Toast Feedback

    /// Push a transient in-app message (success/error/info). Use for user-facing
    /// operations that previously failed silently behind empty catch blocks.
    func presentToast(_ message: String, tone: AgentToast.Tone = .info, retry: (() -> Void)? = nil) {
        var toast = AgentToast(message: message, tone: tone)
        toast.retryAction = retry
        toasts.append(toast)
        if toasts.count > 3 {
            toasts.removeFirst(toasts.count - 3)
        }
    }

    func dismissToast(_ toast: AgentToast) {
        toasts.removeAll { $0.id == toast.id }
    }

    func primeProjectRunProgress(
        project: Project,
        summary: ProjectMissionSummary,
        intent: ProjectCommandIntent,
        operatorNote: String
    ) {
        let note = operatorNote.trimmingCharacters(in: .whitespacesAndNewlines)
        let mission = summary.missionText.trimmingCharacters(in: .whitespacesAndNewlines)
        let nextStep = summary.nextStep.trimmingCharacters(in: .whitespacesAndNewlines)
        let target = mission.isEmpty ? project.mission : mission
        let proof = summary.missionContract.proofRequirement.trimmingCharacters(in: .whitespacesAndNewlines)

        var steps: [WorkspaceProgressStep] = [
            WorkspaceProgressStep(
                id: "project-intent",
                title: intent.displayName,
                detail: note.isEmpty ? intent.instructionFocus : note,
                symbolName: "arrow.triangle.branch",
                state: .current
            ),
            WorkspaceProgressStep(
                id: "project-context",
                title: "Read project context",
                detail: target.isEmpty ? "Load mission, files, timeline, runs, and proof." : target,
                symbolName: "doc.text.magnifyingglass",
                state: .pending
            )
        ]

        switch intent {
        case .continueMission:
            steps.append(WorkspaceProgressStep(
                id: "project-next-step",
                title: "Choose next action",
                detail: nextStep.isEmpty ? "Pick the highest-leverage build step from evidence." : nextStep,
                symbolName: "sparkles",
                state: .pending
            ))
            steps.append(WorkspaceProgressStep(
                id: "project-execute",
                title: "Execute task",
                detail: "Edit, create, or inspect the concrete artifact the project needs next.",
                symbolName: "hammer.fill",
                state: .pending
            ))
        case .planNext:
            steps.append(WorkspaceProgressStep(
                id: "project-plan",
                title: "Draft task plan",
                detail: "Turn the mission into ordered next tasks, blockers, and proof checks.",
                symbolName: "checklist",
                state: .pending
            ))
            steps.append(WorkspaceProgressStep(
                id: "project-plan-save",
                title: "Save direction",
                detail: "Record the chosen next step so future runs know what to do.",
                symbolName: "tray.and.arrow.down.fill",
                state: .pending
            ))
        case .verifyWork:
            steps.append(WorkspaceProgressStep(
                id: "project-verify",
                title: "Run verification",
                detail: proof.isEmpty ? "Use the fastest relevant build, test, screenshot, or smoke check." : proof,
                symbolName: "checkmark.seal.fill",
                state: .pending
            ))
            steps.append(WorkspaceProgressStep(
                id: "project-risk",
                title: "Report risks",
                detail: "Name what passed, what changed, and what remains uncertain.",
                symbolName: "exclamationmark.magnifyingglass",
                state: .pending
            ))
        case .improveArtifact:
            steps.append(WorkspaceProgressStep(
                id: "project-artifact",
                title: "Inspect artifact",
                detail: summary.latestProofTitle.isEmpty ? "Find the latest project output or file to improve." : summary.latestProofTitle,
                symbolName: "shippingbox.fill",
                state: .pending
            ))
            steps.append(WorkspaceProgressStep(
                id: "project-polish",
                title: "Polish output",
                detail: "Improve usefulness, clarity, and proof quality before handing it back.",
                symbolName: "wand.and.stars",
                state: .pending
            ))
        case .fixBlocker:
            steps.append(WorkspaceProgressStep(
                id: "project-reproduce",
                title: "Inspect blocker",
                detail: summary.blocker.isEmpty ? "Find the failing run, error, or stuck approval." : summary.blocker,
                symbolName: "exclamationmark.triangle.fill",
                state: .pending
            ))
            steps.append(WorkspaceProgressStep(
                id: "project-fix",
                title: "Apply fix",
                detail: "Make the smallest useful repair and then verify it.",
                symbolName: "wrench.adjustable.fill",
                state: .pending
            ))
        case .reviewEvidence:
            steps.append(WorkspaceProgressStep(
                id: "project-evidence",
                title: "Review evidence",
                detail: "Read timeline, runs, proof, artifacts, and file changes.",
                symbolName: "text.viewfinder",
                state: .pending
            ))
            steps.append(WorkspaceProgressStep(
                id: "project-recommend",
                title: "Recommend action",
                detail: nextStep.isEmpty ? "Summarize what matters and choose the next safe move." : nextStep,
                symbolName: "lightbulb.fill",
                state: .pending
            ))
        }

        steps.append(WorkspaceProgressStep(
            id: "project-proof",
            title: "Capture proof",
            detail: proof.isEmpty ? "Finish with checks, artifacts, files changed, and any remaining blocker." : proof,
            symbolName: "checkmark.seal.fill",
            state: .pending
        ))
        plannedProgressSteps = steps
        let startingDetail = note.isEmpty ? (nextStep.isEmpty ? intent.instructionFocus : nextStep) : note
        setActivity("Starting \(intent.compactName)", detail: startingDetail)
    }

    func clearPrimedProjectRunProgress() {
        plannedProgressSteps = []
        if !isWorking,
           pendingTool == nil,
           lastRunDuration == nil,
           lastError == nil,
           !wasInterrupted {
            setActivity("Ready", detail: "Waiting for your next request.")
        }
    }

    func clearCurrentRunState(keepLastFailure: Bool = true) {
        isWorking = false
        runState = .idle
        stopRequested = false
        wasInterrupted = false
        if !keepLastFailure {
            lastError = nil
            lastFailedPrompt = nil
        }
        activityTitle = "Ready"
        activityDetail = "Waiting for your next request."
        activeToolName = nil
        activeToolDetail = ""
        traceEvents = []
        plannedProgressSteps = []
        currentArtifacts = []
        queuedFollowUpMessageIDs.removeAll()
        discardQueuedPrompts()
        outgoingProviderRoleLog = ""
        lastRunDuration = nil
        runStartedAt = nil
        currentPrompt = nil
        setLastRunConversation(nil)
    }

    private func startPrompt(
        _ prompt: String,
        conversation: Conversation,
        settings: AgentSettings,
        context: ModelContext,
        project: Project?,
        clearsStaleQueuedFollowUps: Bool = true,
        origin: AgentRunOrigin = .manual,
        visiblePrompt: String? = nil
    ) {
        startPrompt(
            prompt,
            conversation: conversation,
            settings: settings,
            context: context,
            project: project,
            clearsStaleQueuedFollowUps: clearsStaleQueuedFollowUps,
            origin: origin,
            visiblePrompt: visiblePrompt,
            existingVisibleUserMessageID: nil
        )
    }

    private func startPrompt(
        _ prompt: String,
        conversation: Conversation,
        settings: AgentSettings,
        context: ModelContext,
        project: Project?,
        clearsStaleQueuedFollowUps: Bool,
        origin: AgentRunOrigin,
        visiblePrompt: String?,
        existingVisibleUserMessageID: UUID?
    ) {
        if clearsStaleQueuedFollowUps {
            discardQueuedPrompts()
        }

        let activeProject = project ?? conversation.project
        if conversation.project == nil {
            conversation.project = activeProject
        }
        applyProjectIdentitySuggestionIfNeeded(
            to: activeProject,
            conversation: conversation,
            prompt: prompt,
            context: context
        )
        let displayedPrompt = visiblePrompt?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? visiblePrompt! : prompt
        let visibleUserMessage: ChatMessage
        if let existingVisibleUserMessageID,
           let existing = conversation.messages.first(where: { $0.id == existingVisibleUserMessageID }) {
            existing.content = PersistedPayloadBudget.compactMessageContent(displayedPrompt, role: .user)
            existing.conversation = conversation
            visibleUserMessage = existing
            queuedFollowUpMessageIDs.remove(existingVisibleUserMessageID)
            conversation.refreshMessageMetadata(updateTimestamp: Date())
        } else {
            let userMessage = ChatMessage(role: .user, content: displayedPrompt, conversation: conversation)
            conversation.appendMessage(userMessage)
            context.insert(userMessage)
            visibleUserMessage = userMessage
            ProjectEventRecorder.record(
                project: activeProject,
                kind: .promptQueued,
                title: origin == .autoContinued ? "Auto-continued prompt queued" : "Prompt queued",
                detail: displayedPrompt,
                severity: .running,
                sourceType: .conversation,
                sourceID: conversation.id,
                metadata: ["origin": origin.rawValue],
                context: context
            )
        }

        isWorking = true
        runState = .running
        stopRequested = false
        wasInterrupted = false
        runStartedAt = Date()
        currentPrompt = prompt
        setLastRunConversation(conversation)
        liveStream.reset()
        lastError = nil
        lastFailedPrompt = nil
        lastRunDuration = nil
        activeToolName = nil
        activeToolDetail = ""
        currentArtifacts = []
        traceEvents = []
        if project == nil {
            plannedProgressSteps = []
        }
        if settings.provider == .local {
            setActivity("Preparing local model", detail: "Starting a short on-device response.")
        } else {
            setActivity("Reading your request", detail: "Preparing the conversation and workspace context.")
        }
        pushTrace("User prompt queued", detail: prompt, status: .queued)
        if settings.provider == .local {
            pushTrace("Local reply queued", detail: "One-pass local mode keeps the iPhone responsive and avoids fake tool calls.", status: .thinking)
        } else {
            pushTrace("Planning run", detail: "Breaking the request into model and workspace steps.", status: .planning)
        }

        let runID = beginRunIdentity()
        currentTask = Task {
            defer { clearCurrentTaskIfActive(runID) }
            do {
                try saveCompacted(context)
                await runAgentLoop(
                    conversation: conversation,
                    settings: settings,
                    context: context,
                    runID: runID,
                    project: activeProject,
                    origin: origin
                )
            } catch is CancellationError {
                guard isActiveRun(runID) else { return }
                setActivity("Paused", detail: "The run was paused before completion.")
                isWorking = false
                runState = .cancelled
            } catch {
                guard isActiveRun(runID) else { return }
                let message = friendlyError(error)
                lastError = message
                lastFailedPrompt = prompt
                currentPrompt = nil
                isWorking = false
                runState = .failed(message)
                appendVisibleErrorMessage(
                    "I hit an error before NovaForge could send: \(message)",
                    conversation: conversation,
                    context: context,
                    project: activeProject,
                    sourceID: visibleUserMessage.id
                )
                ProjectEventRecorder.record(
                    project: activeProject,
                    kind: .runFailed,
                    title: "Run failed",
                    detail: message,
                    severity: .failure,
                    sourceType: .conversation,
                    sourceID: conversation.id,
                    context: context
                )
                saveCompactedIfPossible(context)
            }
        }
    }

    func approvePendingTool(conversation: Conversation, settings: AgentSettings, context: ModelContext, project: Project? = nil) {
        guard let request = pendingTool else { return }
        let targetConversation = lastRunConversation ?? conversation
        let activeProject = project ?? targetConversation.project ?? pendingApprovalRun?.project
        let approvalRun = pendingApprovalRun
        runStartedAt = runStartedAt ?? Date()
        if let approvalRun {
            let previousStatus = approvalRun.status
            let previousOutput = approvalRun.output
            let previousCompletedAt = approvalRun.completedAt
            approvalRun.status = .approved
            approvalRun.output = "Approved by user; execution started."
            approvalRun.completedAt = nil
            approvalRun.project = approvalRun.project ?? activeProject
            ProjectEventRecorder.record(
                project: activeProject,
                kind: .toolApproved,
                title: "Approved \(request.name)",
                detail: request.argumentsJSON,
                severity: .running,
                sourceType: .toolRun,
                sourceID: approvalRun.id,
                context: context
            )
            do {
                try saveCompacted(context)
            } catch {
                approvalRun.status = previousStatus
                approvalRun.output = previousOutput
                approvalRun.completedAt = previousCompletedAt
                pendingTool = request
                pendingApprovalRun = approvalRun
                isWorking = false
                runState = .waitingForApproval
                let message = friendlyError(error)
                lastError = message
                setActiveTool(request, title: "Approval not saved")
                setActivity(
                    "Approval Not Saved",
                    detail: "NovaForge did not run \(request.name) because the approval could not be saved. Try again after storage recovers."
                )
                pushTrace("Approval not saved", detail: message, status: .failed)
                return
            }
        }
        pendingApprovalRun = nil
        pendingTool = nil
        isWorking = true
        runState = .running
        setActiveTool(request, title: "Running approved tool")
        pushTrace("Approved \(request.name)", detail: request.argumentsJSON, status: .approval)

        let runID = beginRunIdentity()
        currentTask = Task {
            defer { clearCurrentTaskIfActive(runID) }
            let output = await executeTool(request, context: context, project: activeProject, recordRun: false)
            guard isActiveRun(runID) else { return }
            let previousRunStatus = approvalRun?.status
                let previousRunOutput = approvalRun?.output
                let previousRunCompletedAt = approvalRun?.completedAt
                var persistedRun: ToolRun?
                var toolMsg: ChatMessage?
                do {
                    persistedRun = finishApprovalRun(
                        approvalRun,
                        request: request,
                        output: output,
                        status: output.hasPrefix("Error:") ? .failed : .completed,
                        project: activeProject,
                        context: context
                    )
                    rememberArtifact(from: output, project: activeProject, sourceToolRunID: persistedRun?.id, context: context)
                    if request.isMutating {
                        invalidateWorkspaceSummaryCache()
                    }
                    let message = ChatMessage(
                        role: .tool,
                        content: output,
                        toolCallID: request.id,
                        conversation: targetConversation
                    )
                    toolMsg = message
                    targetConversation.appendMessage(message)
                    context.insert(message)
                    try saveCompacted(context)
                } catch {
                    if let approvalRun {
                        if let previousRunStatus {
                            approvalRun.status = previousRunStatus
                        }
                        if let previousRunOutput {
                            approvalRun.output = previousRunOutput
                        }
                        approvalRun.completedAt = previousRunCompletedAt
                        deleteFileChanges(sourceToolRunID: approvalRun.id, context: context)
                        deleteTerminalCommands(sourceToolRunID: approvalRun.id, context: context)
                    } else if let persistedRun {
                        deleteFileChanges(sourceToolRunID: persistedRun.id, context: context)
                        deleteTerminalCommands(sourceToolRunID: persistedRun.id, context: context)
                        context.delete(persistedRun)
                    }
                    if let toolMsg {
                        rollbackUnsavedMessage(toolMsg, from: targetConversation, context: context)
                    }
                    if let artifact = WorkspaceArtifact.fromToolOutput(output) {
                        currentArtifacts.removeAll { $0.id == artifact.id }
                    }
                    let message = friendlyError(error)
                    lastError = message
                    lastFailedPrompt = latestUserPrompt(in: targetConversation)
                    discardQueuedPrompts()
                    isWorking = false
                    runState = .failed(message)
                    setActivity(
                        "Tool Result Not Saved",
                        detail: "NovaForge ran \(request.name), but could not save the tool result. Check storage and retry from the current workspace state."
                    )
                    pushTrace("Tool result not saved", detail: message, status: .failed)
                    return
                }

            await runAgentLoop(
                conversation: targetConversation,
                settings: settings,
                context: context,
                runID: runID,
                project: activeProject
            )
        }
    }

    func rejectPendingTool(conversation: Conversation, settings: AgentSettings, context: ModelContext, project: Project? = nil) {
        guard let request = pendingTool else { return }
        let targetConversation = lastRunConversation ?? conversation
        let activeProject = project ?? targetConversation.project ?? pendingApprovalRun?.project
        let approvalRun = pendingApprovalRun
        let previousRunStatus = approvalRun?.status
        let previousRunOutput = approvalRun?.output
        let previousRunCompletedAt = approvalRun?.completedAt
        runStartedAt = runStartedAt ?? Date()
        isWorking = true
        runState = .running

        let runID = beginRunIdentity()
        currentTask = Task {
            defer { clearCurrentTaskIfActive(runID) }
            var rejectionToolMessage: ChatMessage?
            do {
                finishApprovalRun(
                    approvalRun,
                    request: request,
                    output: "Rejected by user.",
                    status: .rejected,
                    project: activeProject,
                    context: context
                )

                let toolMsg = ChatMessage(
                    role: .tool,
                    content: "Error: Tool execution rejected by the user.",
                    toolCallID: request.id,
                    conversation: targetConversation
                )
                rejectionToolMessage = toolMsg
                targetConversation.appendMessage(toolMsg)
                context.insert(toolMsg)
                try saveCompacted(context)

                pendingApprovalRun = nil
                pendingTool = nil
                setActivity("Tool rejected", detail: request.name)
                pushTrace("Rejected \(request.name)", detail: request.argumentsJSON, status: .failed)

                await runAgentLoop(
                    conversation: targetConversation,
                    settings: settings,
                    context: context,
                    runID: runID,
                    project: activeProject
                )
            } catch {
                guard isActiveRun(runID) else { return }
                if let approvalRun {
                    if let previousRunStatus {
                        approvalRun.status = previousRunStatus
                    }
                    if let previousRunOutput {
                        approvalRun.output = previousRunOutput
                    }
                    approvalRun.completedAt = previousRunCompletedAt
                }
                if let rejectionToolMessage {
                    targetConversation.messages.removeAll { $0.id == rejectionToolMessage.id }
                    rejectionToolMessage.conversation = nil
                    context.delete(rejectionToolMessage)
                    targetConversation.refreshMessageMetadata()
                }
                let message = friendlyError(error)
                lastError = message
                pendingTool = request
                pendingApprovalRun = approvalRun
                isWorking = false
                runState = .waitingForApproval
                setActiveTool(request, title: "Rejection Not Saved")
                setActivity(
                    "Rejection Not Saved",
                    detail: "NovaForge kept the approval open because the rejection could not be saved. Try again after storage recovers."
                )
                pushTrace("Rejection not saved", detail: message, status: .failed)
            }
        }
    }

    func resetWorkspace() throws {
        try workspace.reset()
        invalidateWorkspaceSummaryCache()
        ensureSeedWorkspace()
    }

    func noteWorkspaceChanged() {
        invalidateWorkspaceSummaryCache()
    }

    private func runAgentLoop(
        conversation: Conversation,
        settings: AgentSettings,
        context: ModelContext,
        runID: UUID,
        project: Project?,
        origin: AgentRunOrigin = .manual
    ) async {
        guard isActiveRun(runID) else { return }
        let activeProject = project ?? conversation.project
        if conversation.project == nil {
            conversation.project = activeProject
        }
        isWorking = true
        runState = .running
        lastError = nil
        var shouldDrainQueuedFollowUps = false

        do {
            try AppRootPersistence.repairStaleModelSelection(
                settings: settings,
                save: { try saveCompacted(context) }
            )
            let runProvider = settings.provider
            let runModelID = settings.modelID
            let runTemperature = settings.temperature
            let runCustomSystemPrompt = settings.customSystemPrompt
            let runCustomChatCompletionsURL = settings.resolvedCustomChatCompletionsURL
            let runAutoApproveWrites = origin == .autoContinued ? false : settings.autoApproveWrites

            if runProvider == .local {
                setActivity("Loading local model", detail: "Collecting a tiny context window for \(runModelID).")
            } else {
                setActivity("Syncing workspace", detail: "Collecting files and recent messages for \(runProvider.displayName).")
            }
            let providerConfiguration = ProviderConfiguration(
                provider: runProvider,
                modelID: runModelID,
                apiKey: apiKey(for: runProvider),
                customChatCompletionsURL: runCustomChatCompletionsURL
            )

            #if DEBUG || targetEnvironment(simulator)
            let hasDebugProviderOverride = !debugProviderResponses.isEmpty || debugProviderFailure != nil
            #else
            let hasDebugProviderOverride = false
            #endif
            if runProvider != .local && providerConfiguration.apiKey.isEmpty && !hasDebugProviderOverride {
                let message = "\(runProvider.missingCredentialMessage) NovaForge did not fake a provider response."
                lastError = message
                lastFailedPrompt = currentPrompt
                setActivity("Provider setup needed", detail: message)
                pushTrace("Provider key missing", detail: "No request was sent to \(runProvider.displayName).", status: .failed)
                let assistant = ChatMessage(
                    role: .assistant,
                    content: "I hit an error: \(message)",
                    conversation: conversation
                )
                conversation.appendMessage(assistant)
                context.insert(assistant)
                ProjectEventRecorder.record(
                    project: activeProject,
                    kind: .runFailed,
                    title: "Provider setup needed",
                    detail: message,
                    severity: .failure,
                    sourceType: .conversation,
                    sourceID: conversation.id,
                    context: context
                )
                liveStream.reset()
                isWorking = false
                runState = .failed(message)
                activeToolName = nil
                activeToolDetail = ""
                discardQueuedPrompts()
                runStartedAt = nil
                currentPrompt = nil
                try saveCompacted(context)
                return
            }

            if runProvider == .local,
               let latestPrompt = latestUserPrompt(in: conversation),
               let localPlan = LocalAgentPlanner.plan(prompt: latestPrompt, workspace: workspace) {
                let completedLocalPlan = try await runLocalNativePlan(
                    localPlan,
                    conversation: conversation,
                    context: context,
                    runID: runID,
                    project: activeProject
                )
                guard isActiveRun(runID) else { return }
                if completedLocalPlan {
                    drainQueueIfPossible(conversation: conversation, settings: settings, context: context)
                } else {
                    discardQueuedPrompts()
                }
                return
            }

            if runProvider == .local,
               let latestPrompt = latestUserPrompt(in: conversation),
               let responseText = Self.fastLocalResponseIfNeeded(for: latestPrompt) {
                setActivity("Local mode is safe", detail: "Short local fallback keeps iPhone 12 responsive.")
                await showImmediateResponse(responseText)
                guard isActiveRun(runID) else { return }
                let assistant = ChatMessage(id: liveStream.responseID, role: .assistant, content: responseText, conversation: conversation)
                conversation.appendMessage(assistant)
                context.insert(assistant)
                ProjectEventRecorder.record(
                    project: activeProject,
                    kind: .responseSaved,
                    title: "Local response saved",
                    detail: responseText,
                    severity: .success,
                    sourceType: .message,
                    sourceID: assistant.id,
                    context: context
                )
                ProjectEventRecorder.record(
                    project: activeProject,
                    kind: .runCompleted,
                    title: "Local run completed",
                    detail: "Short local response delivered.",
                    severity: .success,
                    sourceType: .conversation,
                    sourceID: conversation.id,
                    context: context
                )
                do {
                    try saveCompacted(context)
                } catch {
                    rollbackUnsavedMessage(assistant, from: conversation, context: context)
                    throw error
                }
                liveStream.finishHandoff(to: assistant.id)
                pushTrace("Local safe response", detail: "Skipped unstable local generation for this prompt.", status: .success)
                isWorking = false
                runState = .completed
                activeToolName = nil
                activeToolDetail = ""
                if let runStartedAt {
                    lastRunDuration = Date().timeIntervalSince(runStartedAt)
                }
                runStartedAt = nil
                currentPrompt = nil
                drainQueueIfPossible(conversation: conversation, settings: settings, context: context)
                return
            }

            var toolRoundCount = 0
            while true {
                try Task.checkCancellation()
                guard !stopRequested else { throw CancellationError() }
                toolRoundCount += 1
                guard toolRoundCount <= maxToolRoundCount else { throw AgentRuntimeError.tooManyToolRounds }
                let summary = workspaceSummaryForProvider(runProvider)
                setActivity("Calling \(runProvider.shortName)", detail: "Routing through \(runModelID).")

                let history = providerHistory(for: conversation, limit: 96)
                liveStream.reset()
                let providerResponse: ProviderResponse
                if runProvider == .local {
                    let variant = LocalModelCatalog.variant(for: runModelID) ?? LocalModelCatalog.defaultVariant
                    setActivity("Starting \(variant.shortName)", detail: "\(variant.executionLabel) · \(variant.contextTokens) context · \(variant.maxNewTokens) token cap.")
                    pushTrace("Local model starting", detail: "\(variant.shortName), \(variant.executionLabel), \(variant.contextTokens) context tokens.", status: .thinking)
                    providerResponse = try await localResponseWithWatchdog(
                        messages: history,
                        model: runModelID,
                        temperature: runTemperature,
                        customSystemPrompt: runCustomSystemPrompt,
                        workspaceSummary: summary,
                        runID: runID,
                        onContentBatch: { batch in
                            guard self.isActiveRun(runID) else { return }
                            self.liveStream.append(batch)
                        }
                    )
                } else {
                    providerResponse = try await responseWithRecovery(
                        configuration: providerConfiguration,
                        messages: history,
                        model: runModelID,
                        temperature: runTemperature,
                        customSystemPrompt: runCustomSystemPrompt,
                        workspaceSummary: summary,
                        runID: runID,
                        onContentBatch: { batch in
                            guard self.isActiveRun(runID) else { return }
                            self.liveStream.append(batch)
                        }
                    )
                }
                try requireActiveRun(runID)
                liveStream.flushPending()
                let response = providerResponse.message
                outgoingProviderRoleLog = providerResponse.roleLog

                if let toolCalls = response.tool_calls, !toolCalls.isEmpty {
                    let effectiveToolCalls: [APIToolCall]
                    if !runAutoApproveWrites,
                       let firstApprovalIndex = toolCalls.firstIndex(where: { ToolRequest(id: $0.id, name: $0.function.name, arguments: parseArguments($0.function.arguments)).isMutating }) {
                        // Pause on the first mutating call, and persist only the
                        // tool_calls that can be answered before that pause. If a
                        // later call stayed in the assistant message without a tool
                        // result, the provider transcript sanitizer would correctly
                        // drop the whole exchange as incomplete after approval.
                        effectiveToolCalls = Array(toolCalls.prefix(through: firstApprovalIndex))
                    } else {
                        effectiveToolCalls = toolCalls
                    }

                    setActivity("Tool plan ready", detail: "\(effectiveToolCalls.count) action\(effectiveToolCalls.count == 1 ? "" : "s") queued.")
                    pushTrace("Model requested tools", detail: effectiveToolCalls.map { $0.function.name }.joined(separator: ", "), status: .tool)
                    let encoder = JSONEncoder()
                    let toolCallsJSON = (try? encoder.encode(effectiveToolCalls)).flatMap { String(data: $0, encoding: .utf8) }

                    let assistant = ChatMessage(
                        id: liveStream.responseID,
                        role: .assistant,
                        content: response.content ?? "",
                        toolCallsJSON: toolCallsJSON,
                        conversation: conversation
                    )
                    conversation.appendMessage(assistant)
                    context.insert(assistant)
                    ProjectEventRecorder.record(
                        project: activeProject,
                        kind: .responseSaved,
                        title: "Assistant tool plan saved",
                        detail: response.content ?? "",
                        severity: .running,
                        sourceType: .message,
                        sourceID: assistant.id,
                        context: context
                    )
                    ProjectEventRecorder.record(
                        project: activeProject,
                        kind: .agentPlanCreated,
                        title: "Agent plan prepared",
                        detail: effectiveToolCalls.map { $0.function.name }.joined(separator: ", "),
                        severity: .running,
                        sourceType: .message,
                        sourceID: assistant.id,
                        context: context
                    )
                    ProjectEventRecorder.recordMissionCheckpoint(
                        project: activeProject,
                        trigger: "provider-tool-plan",
                        sourceType: .message,
                        sourceID: assistant.id,
                        context: context
                    )
                    try saveCompacted(context)
                    liveStream.finishHandoff(to: assistant.id)

                    var pausedForApproval = false
                    var toolMessages: [ChatMessage] = []
                    var persistedToolRuns: [ToolRun] = []
                    var rememberedArtifacts: [WorkspaceArtifact] = []

                    for call in effectiveToolCalls {
                        let parsedArgs = parseArguments(call.function.arguments)
                        let toolReq = ToolRequest(id: call.id, name: call.function.name, arguments: parsedArgs)
                        setActiveTool(toolReq, title: toolReq.isMutating ? "Preparing workspace change" : "Inspecting workspace")
                        pushTrace("Queued \(toolReq.name)", detail: toolReq.argumentsJSON, status: .tool)

                        if toolReq.isMutating && !runAutoApproveWrites {
                            pendingTool = toolReq
                            runState = .waitingForApproval
                            pausedForApproval = true
                            setActiveTool(toolReq, title: "Approval needed")
                            pushTrace("Approval needed", detail: toolReq.argumentsJSON, status: .approval)

                            let run = ToolRun(
                                name: toolReq.name,
                                argumentsJSON: toolReq.argumentsJSON,
                                status: .pendingApproval,
                                requiresApproval: true,
                                isMutating: true,
                                project: activeProject
                            )
                            pendingApprovalRun = run
                            context.insert(run)
                            ProjectEventRecorder.record(
                                project: activeProject,
                                kind: .toolApprovalRequested,
                                title: "Approval needed for \(toolReq.name)",
                                detail: toolReq.argumentsJSON,
                                severity: .warning,
                                sourceType: .toolRun,
                                sourceID: run.id,
                                context: context
                            )
                            try saveCompacted(context)
                            break
                        } else {
                            let output = await executeTool(toolReq, context: context, project: activeProject, recordRun: false)
                            try requireActiveRun(runID)
                            try Task.checkCancellation()
                            if toolReq.isMutating { invalidateWorkspaceSummaryCache() }
                            let run = insertToolRun(
                                request: toolReq,
                                output: output,
                                status: output.hasPrefix("Error:") ? .failed : .completed,
                                project: activeProject,
                                context: context
                            )
                            persistedToolRuns.append(run)
                            if let artifact = WorkspaceArtifact.fromToolOutput(output) {
                                currentArtifacts.removeAll { $0.id == artifact.id }
                                currentArtifacts.insert(artifact, at: 0)
                                if currentArtifacts.count > 8 {
                                    currentArtifacts.removeLast(currentArtifacts.count - 8)
                                }
                                ProjectEventRecorder.ensureArtifact(
                                    artifact,
                                    project: activeProject,
                                    sourceToolRunID: run.id,
                                    context: context
                                )
                                rememberedArtifacts.append(artifact)
                            }
                            pushTrace("Finished \(toolReq.name)", detail: compactOutputSummary(output), status: output.hasPrefix("Error:") ? .failed : .success)
                            let toolMsg = ChatMessage(
                                role: .tool,
                                content: output,
                                toolCallID: call.id,
                                conversation: conversation
                            )
                            conversation.appendMessage(toolMsg)
                            context.insert(toolMsg)
                            toolMessages.append(toolMsg)
                        }
                    }

                    if pausedForApproval {
                        isWorking = false
                        return
                    }

                    do {
                        try saveCompacted(context)
                    } catch {
                        for message in toolMessages.reversed() {
                            rollbackUnsavedMessage(message, from: conversation, context: context)
                        }
                        for run in persistedToolRuns {
                            deleteFileChanges(sourceToolRunID: run.id, context: context)
                            deleteTerminalCommands(sourceToolRunID: run.id, context: context)
                            context.delete(run)
                        }
                        rollbackUnsavedMessage(assistant, from: conversation, context: context)
                        for artifact in rememberedArtifacts {
                            currentArtifacts.removeAll { $0.id == artifact.id }
                        }
                        let message = friendlyError(error)
                        lastError = message
                        lastFailedPrompt = latestUserPrompt(in: conversation)
                        discardQueuedPrompts()
                        isWorking = false
                        runState = .failed(message)
                        activeToolName = nil
                        activeToolDetail = ""
                        if let runStartedAt {
                            lastRunDuration = Date().timeIntervalSince(runStartedAt)
                        }
                        runStartedAt = nil
                        currentPrompt = nil
                        setActivity(
                            "Tool Results Not Saved",
                            detail: "NovaForge ran provider-requested tools, but could not save their transcript. Check storage and retry."
                        )
                        pushTrace("Tool results not saved", detail: message, status: .failed)
                        return
                    }
                    liveStream.finishHandoff(to: assistant.id)
                    activeToolName = nil
                    activeToolDetail = ""
                    setActivity("Reading tool output", detail: "Sending results back to the model.")
                    try? await Task.sleep(for: .milliseconds(500))
                    try requireActiveRun(runID)
                    continue
                }

                let text = response.content ?? "I have finished processing your request."
                setActivity("Finalizing response", detail: "Saving the live model output to the chat.")

                let assistant = ChatMessage(
                    id: liveStream.responseID,
                    role: .assistant,
                    content: text,
                    conversation: conversation
                )
                conversation.appendMessage(assistant)
                context.insert(assistant)
                ProjectEventRecorder.record(
                    project: activeProject,
                    kind: .responseSaved,
                    title: "Response saved",
                    detail: text,
                    severity: .success,
                    sourceType: .message,
                    sourceID: assistant.id,
                    context: context
                )
                do {
                    try saveCompacted(context)
                } catch {
                    rollbackUnsavedMessage(assistant, from: conversation, context: context)
                    throw error
                }
                liveStream.finishHandoff(to: assistant.id)
                pushTrace("Response complete", detail: "\(text.count) characters delivered.", status: .success)
                ProjectEventRecorder.record(
                    project: activeProject,
                    kind: .runCompleted,
                    title: "Run completed",
                    detail: "\(text.count) characters delivered.",
                    severity: .success,
                    sourceType: .conversation,
                    sourceID: conversation.id,
                    context: context
                )
                ProjectEventRecorder.record(
                    project: activeProject,
                    kind: .agentProofCreated,
                    title: "Agent proof captured",
                    detail: currentArtifacts.isEmpty ? "Final response saved." : currentArtifacts.map(\.path).joined(separator: ", "),
                    severity: .success,
                    sourceType: .conversation,
                    sourceID: conversation.id,
                    context: context
                )
                ProjectEventRecorder.recordMissionCheckpoint(
                    project: activeProject,
                    trigger: "provider-agent-proof",
                    sourceType: .conversation,
                    sourceID: conversation.id,
                    context: context
                )
                saveCompactedIfPossible(context)
                runState = .completed
                shouldDrainQueuedFollowUps = true
                break
            }
        } catch {
            guard isActiveRun(runID) else { return }
            if error is CancellationError || ((error as? URLError)?.code == .cancelled && stopRequested) {
                setActivity("Paused", detail: "The active run was paused.")
                pushTrace("Run paused", detail: "No provider messages were added after pausing.", status: .paused)
                ProjectEventRecorder.record(
                    project: activeProject,
                    kind: .runPaused,
                    title: "Run paused",
                    detail: "No provider messages were added after pausing.",
                    severity: .warning,
                    sourceType: .conversation,
                    sourceID: conversation.id,
                    context: context
                )
                runState = .cancelled
                discardQueuedPrompts()
            } else if case AgentRuntimeError.tooManyToolRounds = error {
                let message = "Paused after \(maxToolRoundCount) tool rounds. NovaForge saved the project run so you can continue without restarting completed work."
                lastError = nil
                lastFailedPrompt = latestUserPrompt(in: conversation)
                wasInterrupted = true
                setActivity("Paused at tool limit", detail: message)
                pushTrace("Tool limit reached", detail: message, status: .paused)
                ProjectEventRecorder.record(
                    project: activeProject,
                    kind: .runPaused,
                    title: "Run paused at tool limit",
                    detail: message,
                    severity: .warning,
                    sourceType: .conversation,
                    sourceID: conversation.id,
                    metadata: [
                        "maxToolRounds": "\(maxToolRoundCount)",
                        "resume": "true"
                    ],
                    context: context
                )
                let assistant = ChatMessage(
                    role: .assistant,
                    content: "ProjectOS paused at NovaForge's tool-call safety limit after saving progress. Tap Continue to resume from the current state instead of starting over.",
                    conversation: conversation
                )
                conversation.appendMessage(assistant)
                context.insert(assistant)
                runState = .cancelled
                discardQueuedPrompts()
                do {
                    try saveCompacted(context)
                } catch {
                    rollbackUnsavedMessage(assistant, from: conversation, context: context)
                    let saveMessage = friendlyError(error)
                    lastError = saveMessage
                    setActivity("Pause Not Saved", detail: saveMessage)
                    pushTrace("Pause state not saved", detail: saveMessage, status: .failed)
                    runState = .failed(saveMessage)
                }
            } else {
                let message = friendlyError(error)
                lastError = message
                lastFailedPrompt = latestUserPrompt(in: conversation)
                setActivity("Something needs attention", detail: message)
                pushTrace("Run failed", detail: message, status: .failed)
                ProjectEventRecorder.record(
                    project: activeProject,
                    kind: .runFailed,
                    title: "Run failed",
                    detail: message,
                    severity: .failure,
                    sourceType: .conversation,
                    sourceID: conversation.id,
                    context: context
                )
                runState = .failed(message)
                discardQueuedPrompts()
                let assistant = ChatMessage(
                    role: .assistant,
                    content: "I hit an error: \(message)",
                    conversation: conversation
                )
                conversation.appendMessage(assistant)
                context.insert(assistant)
                do {
                    try saveCompacted(context)
                } catch {
                    rollbackUnsavedMessage(assistant, from: conversation, context: context)
                    let saveMessage = friendlyError(error)
                    lastError = saveMessage
                    setActivity(
                        "Error Not Saved",
                        detail: "NovaForge could not save the error transcript. \(saveMessage)"
                    )
                    pushTrace("Error transcript not saved", detail: saveMessage, status: .failed)
                    runState = .failed(saveMessage)
                }
            }
        }

        guard isActiveRun(runID) else { return }
        isWorking = false
        if !liveStream.isHandoffActive {
            liveStream.reset()
        }
        activeToolName = nil
        activeToolDetail = ""
        if let runStartedAt {
            lastRunDuration = Date().timeIntervalSince(runStartedAt)
        }
        runStartedAt = nil
        currentPrompt = nil
        if shouldDrainQueuedFollowUps {
            drainQueueIfPossible(conversation: conversation, settings: settings, context: context)
        }
    }

    private func executeTool(_ request: ToolRequest, context: ModelContext, project: Project?, recordRun: Bool = true) async -> String {
        let workspace = workspace
        let task = Task.detached(priority: .userInitiated) {
            do {
                try Task.checkCancellation()
                let output = try SandboxToolExecutor(workspace: workspace).execute(request)
                try Task.checkCancellation()
                return (output, ToolRunStatus.completed)
            } catch is CancellationError {
                return ("Error: tool cancelled.", ToolRunStatus.failed)
            } catch {
                return ("Error: \(error.localizedDescription)", ToolRunStatus.failed)
            }
        }
        let result = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        let output = result.0

        if recordRun, !Task.isCancelled {
            insertToolRun(
                request: request,
                output: output,
                status: result.1,
                project: project,
                context: context
            )
        }
        return output
    }

    private func applyProjectIdentitySuggestionIfNeeded(
        to project: Project?,
        conversation: Conversation,
        prompt: String,
        context: ModelContext
    ) {
        guard let project, ProjectNamingEngine.shouldRename(project) else { return }
        let projects = (try? context.fetch(FetchDescriptor<Project>())) ?? []
        let existingNames = Set(projects.filter { $0.id != project.id }.map(\.name))
        guard let suggestion = ProjectNamingEngine.suggestedIdentity(
            prompt: prompt,
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
            context: context
        )
    }

    @discardableResult
    private func finishApprovalRun(
        _ run: ToolRun?,
        request: ToolRequest,
        output: String,
        status: ToolRunStatus,
        project: Project?,
        context: ModelContext
    ) -> ToolRun {
        let persistedOutput = PersistedPayloadBudget.compactToolRunOutput(output)
        if let run {
            run.project = run.project ?? project
            run.output = persistedOutput
            run.status = status
            run.completedAt = Date()
            ProjectEventRecorder.record(
                project: run.project ?? project,
                kind: status == .completed ? .toolCompleted : status == .rejected ? .toolRejected : .toolFailed,
                title: "\(status == .completed ? "Finished" : status == .rejected ? "Rejected" : "Failed") \(request.name)",
                detail: compactOutputSummary(output),
                severity: status == .completed ? .success : status == .rejected ? .warning : .failure,
                sourceType: .toolRun,
                sourceID: run.id,
                context: context
            )
            let terminalRecord = recordTerminalCommandIfNeeded(
                request: request,
                output: output,
                status: status,
                run: run,
                project: run.project ?? project,
                context: context
            )
            recordFileChangesIfNeeded(
                request: request,
                output: output,
                status: status,
                run: run,
                project: run.project ?? project,
                sourceTerminalCommandID: terminalRecord?.id,
                context: context
            )
            return run
        } else {
            return insertToolRun(
                request: request,
                output: persistedOutput,
                status: status,
                project: project,
                context: context
            )
        }
    }

    @discardableResult
    private func insertToolRun(
        request: ToolRequest,
        output: String,
        status: ToolRunStatus,
        project: Project?,
        context: ModelContext
    ) -> ToolRun {
        let run = ToolRun(
            name: request.name,
            argumentsJSON: request.argumentsJSON,
            output: output,
            status: status,
            requiresApproval: request.isMutating,
            isMutating: request.isMutating,
            project: project
        )
        run.completedAt = Date()
        context.insert(run)
        ProjectEventRecorder.record(
            project: project,
            kind: status == .completed ? .toolCompleted : .toolFailed,
            title: "\(status == .completed ? "Finished" : "Failed") \(request.name)",
            detail: compactOutputSummary(output),
            severity: status == .completed ? .success : .failure,
            sourceType: .toolRun,
            sourceID: run.id,
            context: context
        )
        let terminalRecord = recordTerminalCommandIfNeeded(
            request: request,
            output: output,
            status: status,
            run: run,
            project: project,
            context: context
        )
        recordFileChangesIfNeeded(
            request: request,
            output: output,
            status: status,
            run: run,
            project: project,
            sourceTerminalCommandID: terminalRecord?.id,
            context: context
        )
        return run
    }

    @discardableResult
    private func recordTerminalCommandIfNeeded(
        request: ToolRequest,
        output: String,
        status: ToolRunStatus,
        run: ToolRun,
        project: Project?,
        context: ModelContext
    ) -> TerminalCommandRecord? {
        guard request.name == "run_command",
              status == .completed || status == .failed,
              let command = request.arguments["command"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !command.isEmpty else { return nil }

        let completedAt = run.completedAt ?? Date()
        let terminalStatus: TerminalCommandStatus = status == .completed ? .completed : .failed
        let record = TerminalCommandRecord(
            project: project,
            command: command,
            output: output,
            status: terminalStatus,
            workspaceName: workspace.workspaceName,
            startedAt: run.createdAt,
            completedAt: completedAt,
            durationMs: completedAt.timeIntervalSince(run.createdAt) * 1000.0,
            sourceToolRunID: run.id
        )
        context.insert(record)
        ProjectEventRecorder.record(
            project: project,
            kind: .terminalCommand,
            title: terminalStatus == .completed ? "Agent command completed" : "Agent command failed",
            detail: command,
            severity: terminalStatus == .completed ? .success : .failure,
            sourceType: .terminalCommand,
            sourceID: record.id,
            metadata: [
                "command": command,
                "workspace": workspace.workspaceName,
                "toolRun": run.id.uuidString
            ],
            context: context
        )
        return record
    }

    private func recordFileChangesIfNeeded(
        request: ToolRequest,
        output: String,
        status: ToolRunStatus,
        run: ToolRun,
        project: Project?,
        sourceTerminalCommandID: UUID? = nil,
        context: ModelContext
    ) {
        guard status == .completed, request.isMutating, !output.hasPrefix("Error:") else { return }
        for change in toolFileChanges(for: request, output: output) {
            ProjectEventRecorder.recordFileChange(
                project: project,
                action: change.action,
                path: change.path,
                sourceToolRunID: run.id,
                sourceTerminalCommandID: sourceTerminalCommandID,
                context: context
            )
        }
    }

    private func toolFileChanges(for request: ToolRequest, output: String) -> [(action: String, path: String)] {
        switch request.name {
        case "write_file":
            return pathArgument("path", in: request).map { [("Wrote file", $0)] } ?? []
        case "append_file":
            return pathArgument("path", in: request).map { [("Appended file", $0)] } ?? []
        case "replace_text":
            guard output.hasPrefix("Replaced ") else { return [] }
            return pathArgument("path", in: request).map { [("Replaced text", $0)] } ?? []
        case "delete_path":
            return pathArgument("path", in: request).map { [("Deleted path", $0)] } ?? []
        case "move_path":
            guard let source = pathArgument("from", in: request),
                  let destination = pathArgument("to", in: request) else { return [] }
            return [("Moved path", "\(source) -> \(destination)")]
        case "copy_path":
            guard let source = pathArgument("from", in: request),
                  let destination = pathArgument("to", in: request) else { return [] }
            return [("Copied path", "\(source) -> \(destination)")]
        case "make_directory":
            return pathArgument("path", in: request).map { [("Created folder", $0)] } ?? []
        case "run_command":
            guard let command = request.arguments["command"]?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !command.isEmpty else { return [] }
            return [("Ran mutating command", command)]
        default:
            return []
        }
    }

    private func pathArgument(_ key: String, in request: ToolRequest) -> String? {
        guard let value = request.arguments[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        return value
    }

    private func deleteFileChanges(sourceToolRunID: UUID, context: ModelContext) {
        let sourceID = sourceToolRunID.uuidString
        let changes = (try? context.fetch(FetchDescriptor<ProjectFileChange>())) ?? []
        let events = (try? context.fetch(FetchDescriptor<ProjectEvent>())) ?? []
        for change in changes where change.sourceToolRunIDString == sourceID {
            for event in events where event.kind == .fileChanged && event.sourceIDString == change.id.uuidString {
                context.delete(event)
            }
            context.delete(change)
        }
    }

    private func deleteTerminalCommands(sourceToolRunID: UUID, context: ModelContext) {
        let sourceID = sourceToolRunID.uuidString
        let commands = (try? context.fetch(FetchDescriptor<TerminalCommandRecord>())) ?? []
        let events = (try? context.fetch(FetchDescriptor<ProjectEvent>())) ?? []
        for command in commands where command.sourceToolRunIDString == sourceID {
            for event in events where event.kind == .terminalCommand && event.sourceIDString == command.id.uuidString {
                context.delete(event)
            }
            context.delete(command)
        }
    }

    private func typeOut(_ text: String) async {
        liveStream.reset()
        var index = text.startIndex
        while index < text.endIndex {
            guard !Task.isCancelled else { return }
            let end = text.index(index, offsetBy: 220, limitedBy: text.endIndex) ?? text.endIndex
            liveStream.append(String(text[index..<end]))
            index = end
            if index < text.endIndex {
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        liveStream.flushPending()
    }

    private func showImmediateResponse(_ text: String) async {
        await typeOut(text)
    }

    @discardableResult
    private func runLocalNativePlan(
        _ plan: LocalAgentPlan,
        conversation: Conversation,
        context: ModelContext,
        runID: UUID,
        project: Project?
    ) async throws -> Bool {
        guard isActiveRun(runID) else { return false }
        let activeProject = project ?? conversation.project
        liveStream.reset()
        setActivity("Planning local tools", detail: "\(plan.toolCalls.count) native action\(plan.toolCalls.count == 1 ? "" : "s") ready.")
        pushTrace("Local tool plan ready", detail: plan.toolCalls.map { $0.function.name }.joined(separator: ", "), status: .tool)

        let encoder = JSONEncoder()
        let toolCallsJSON = (try? encoder.encode(plan.toolCalls)).flatMap { String(data: $0, encoding: .utf8) }
        let assistant = ChatMessage(
            role: .assistant,
            content: plan.intro,
            toolCallsJSON: toolCallsJSON,
            conversation: conversation
        )
        conversation.appendMessage(assistant)
        context.insert(assistant)
        ProjectEventRecorder.record(
            project: activeProject,
            kind: .responseSaved,
            title: "Local tool plan saved",
            detail: plan.intro,
            severity: .running,
            sourceType: .message,
            sourceID: assistant.id,
            context: context
        )
        ProjectEventRecorder.record(
            project: activeProject,
            kind: .agentPlanCreated,
            title: "Agent plan prepared",
            detail: plan.toolCalls.map { $0.function.name }.joined(separator: ", "),
            severity: .running,
            sourceType: .message,
            sourceID: assistant.id,
            context: context
        )
        ProjectEventRecorder.recordMissionCheckpoint(
            project: activeProject,
            trigger: "local-tool-plan",
            sourceType: .message,
            sourceID: assistant.id,
            context: context
        )
        try saveCompacted(context)

        var failedToolSummaries: [String] = []
        for call in plan.toolCalls {
            guard !Task.isCancelled, !stopRequested else { break }
            let request = ToolRequest(
                id: call.id,
                name: call.function.name,
                arguments: parseArguments(call.function.arguments)
            )
            setActiveTool(request, title: request.isMutating ? "Updating workspace" : "Inspecting workspace")
            pushTrace("Running \(request.name)", detail: request.argumentsJSON, status: .executing)
            let output = await executeTool(request, context: context, project: activeProject, recordRun: false)
            guard isActiveRun(runID), !Task.isCancelled, !stopRequested else { break }
            if request.isMutating { invalidateWorkspaceSummaryCache() }
            let toolRun = insertToolRun(
                request: request,
                output: output,
                status: output.hasPrefix("Error:") ? .failed : .completed,
                project: activeProject,
                context: context
            )
            rememberArtifact(from: output, project: activeProject, sourceToolRunID: toolRun.id, context: context)
            pushTrace("Finished \(request.name)", detail: compactOutputSummary(output), status: output.hasPrefix("Error:") ? .failed : .success)
            if output.hasPrefix("Error:") {
                failedToolSummaries.append("\(request.name): \(compactOutputSummary(output))")
            }
            let toolMessage = ChatMessage(
                role: .tool,
                content: output,
                toolCallID: call.id,
                conversation: conversation
            )
            conversation.appendMessage(toolMessage)
            context.insert(toolMessage)
        }

        guard isActiveRun(runID), !Task.isCancelled, !stopRequested else {
            setActivity("Paused", detail: "Local tool run stopped before the final response was saved.")
            pushTrace("Run paused", detail: "Stopped before adding a completion message.", status: .paused)
            ProjectEventRecorder.record(
                project: activeProject,
                kind: .runPaused,
                title: "Local run paused",
                detail: "Stopped before adding a completion message.",
                severity: .warning,
                sourceType: .conversation,
                sourceID: conversation.id,
                context: context
            )
            runState = .cancelled
            isWorking = false
            activeToolName = nil
            activeToolDetail = ""
            if let runStartedAt {
                lastRunDuration = Date().timeIntervalSince(runStartedAt)
            }
            runStartedAt = nil
            return false
        }

        try saveCompacted(context)
        activeToolName = nil
        activeToolDetail = ""
        if !failedToolSummaries.isEmpty {
            let failureSummary = failedToolSummaries.joined(separator: "\n")
            let finalText = "Agent Proof: the run stopped after a tool failure.\n\(failureSummary)\nNext step: review the failed evidence and retry the run."
            setActivity("Local run failed", detail: compactOutputSummary(failureSummary))
            let final = ChatMessage(role: .assistant, content: finalText, conversation: conversation)
            conversation.appendMessage(final)
            context.insert(final)
            ProjectEventRecorder.record(
                project: activeProject,
                kind: .responseSaved,
                title: "Local failure saved",
                detail: finalText,
                severity: .failure,
                sourceType: .message,
                sourceID: final.id,
                context: context
            )
            ProjectEventRecorder.record(
                project: activeProject,
                kind: .runFailed,
                title: "Local run failed",
                detail: failureSummary,
                severity: .failure,
                sourceType: .conversation,
                sourceID: conversation.id,
                context: context
            )
            ProjectEventRecorder.record(
                project: activeProject,
                kind: .agentProofCreated,
                title: "Agent proof captured",
                detail: failureSummary,
                severity: .failure,
                sourceType: .conversation,
                sourceID: conversation.id,
                context: context
            )
            ProjectEventRecorder.recordMissionCheckpoint(
                project: activeProject,
                trigger: "local-agent-proof-failure",
                sourceType: .conversation,
                sourceID: conversation.id,
                context: context
            )
            try saveCompacted(context)
            pushTrace("Local run failed", detail: compactOutputSummary(failureSummary), status: .failed)
            lastError = compactOutputSummary(failureSummary)
            lastFailedPrompt = latestUserPrompt(in: conversation)
            runState = .failed(lastError ?? "Local tool run failed.")
            isWorking = false
            if let runStartedAt {
                lastRunDuration = Date().timeIntervalSince(runStartedAt)
            }
            runStartedAt = nil
            currentPrompt = nil
            return false
        }

        setActivity("Saving result", detail: "Local tool run completed.")
        let final = ChatMessage(role: .assistant, content: plan.completion, conversation: conversation)
        conversation.appendMessage(final)
        context.insert(final)
        ProjectEventRecorder.record(
            project: activeProject,
            kind: .responseSaved,
            title: "Local completion saved",
            detail: plan.completion,
            severity: .success,
            sourceType: .message,
            sourceID: final.id,
            context: context
        )
        ProjectEventRecorder.record(
            project: activeProject,
            kind: .runCompleted,
            title: "Local run complete",
            detail: plan.completion,
            severity: .success,
            sourceType: .conversation,
            sourceID: conversation.id,
            context: context
        )
        ProjectEventRecorder.record(
            project: activeProject,
            kind: .agentProofCreated,
            title: "Agent proof captured",
            detail: plan.completion,
            severity: .success,
            sourceType: .conversation,
            sourceID: conversation.id,
            context: context
        )
        ProjectEventRecorder.recordMissionCheckpoint(
            project: activeProject,
            trigger: "local-agent-proof",
            sourceType: .conversation,
            sourceID: conversation.id,
            context: context
        )
        try saveCompacted(context)
        pushTrace("Local run complete", detail: plan.completion, status: .success)
        runState = .completed
        isWorking = false
        if let runStartedAt {
            lastRunDuration = Date().timeIntervalSince(runStartedAt)
        }
        runStartedAt = nil
        currentPrompt = nil
        return true
    }

    private func parseArguments(_ json: String) -> [String: String] {
        guard let data = json.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return dict.reduce(into: [String: String]()) { result, element in
            if let str = element.value as? String {
                result[element.key] = str
            } else if let num = element.value as? NSNumber {
                result[element.key] = num.stringValue
            } else if let bool = element.value as? Bool {
                result[element.key] = bool ? "true" : "false"
            }
        }
    }

    private func saveCompacted(_ context: ModelContext) throws {
        PersistedPayloadBudget.compactBeforeSave(in: context)
        #if DEBUG || targetEnvironment(simulator)
        if let debugCompactedSaveOverride {
            try debugCompactedSaveOverride(context)
            return
        }
        #endif
        try context.save()
    }

    private func saveCompactedIfPossible(_ context: ModelContext?) {
        guard let context else { return }
        PersistedPayloadBudget.compactBeforeSave(in: context)
        try? context.save()
    }

    private func appendVisibleErrorMessage(
        _ text: String,
        conversation: Conversation,
        context: ModelContext,
        project: Project?,
        sourceID: UUID?
    ) {
        let assistant = ChatMessage(role: .assistant, content: text, conversation: conversation)
        conversation.appendMessage(assistant)
        context.insert(assistant)
        ProjectEventRecorder.record(
            project: project,
            kind: .runFailed,
            title: "Error shown in transcript",
            detail: text,
            severity: .failure,
            sourceType: .message,
            sourceID: sourceID ?? assistant.id,
            context: context
        )
        do {
            try saveCompacted(context)
        } catch {
            rollbackUnsavedMessage(assistant, from: conversation, context: context)
            presentToast("NovaForge could not save the error transcript: \(friendlyError(error))", tone: .error)
        }
    }

    private func localAnswer(for prompt: String) -> String {
        if prompt.lowercased().contains("command") {
            return "I can run safe sandbox commands like `ls`, `cat`, `mkdir`, `touch`, `grep`, `find`, `wc`, `head`, and `validate_html`. Add an API key in Settings when you want live model reasoning."
        }
        return "NovaForge is ready. I can help with files in this iOS sandbox. Add an API key for your selected provider in Settings, or ask me to create a file to test the approval flow."
    }

    private func beginRunIdentity() -> UUID {
        let runID = UUID()
        activeRunID = runID
        return runID
    }

    private func isActiveRun(_ runID: UUID) -> Bool {
        activeRunID == runID
    }

    private func requireActiveRun(_ runID: UUID) throws {
        guard isActiveRun(runID), !Task.isCancelled, !stopRequested else {
            throw CancellationError()
        }
    }

    private func clearCurrentTaskIfActive(_ runID: UUID) {
        guard isActiveRun(runID) else { return }
        currentTask = nil
        activeRunID = nil
    }

    private func setActivity(_ title: String, detail: String) {
        if activityTitle != title {
            activityTitle = title
        }
        if activityDetail != detail {
            activityDetail = detail
        }
        if isWorking {
            RunActivityController.shared.runProgressed(
                phase: pendingTool != nil ? "Approve" : "Build",
                statusLine: title
            )
        }
        RunActivityController.shared.syncWidgetSnapshot(
            projectName: workspace.workspaceName,
            statusHeadline: title,
            journeyPhase: isWorking ? "Build" : "Plan",
            proofCount: 0
        )
    }

    private func updateActiveTool(name: String?, detail: String = "") {
        if activeToolName != name {
            activeToolName = name
        }
        if activeToolDetail != detail {
            activeToolDetail = detail
        }
    }

    private func clearActiveTool() {
        updateActiveTool(name: nil)
    }

    private func setActiveTool(_ request: ToolRequest, title: String) {
        updateActiveTool(name: request.name, detail: compactToolDetail(request))
        setActivity(title, detail: request.name)
    }

    private func pushTrace(_ title: String, detail: String, status: AgentTraceStatus) {
        let trimmedDetail = detail.trimmingCharacters(in: .whitespacesAndNewlines)
        let cappedDetail = trimmedDetail.count > 180 ? String(trimmedDetail.prefix(180)) + "..." : trimmedDetail
        traceEvents.insert(AgentTraceEvent(title: title, detail: cappedDetail, status: status), at: 0)
        if traceEvents.count > 10 {
            traceEvents.removeLast(traceEvents.count - 10)
        }
    }

    private func rememberArtifact(from output: String, project: Project?, sourceToolRunID: UUID?, context: ModelContext) {
        guard let artifact = WorkspaceArtifact.fromToolOutput(output) else { return }
        currentArtifacts.removeAll { $0.id == artifact.id }
        currentArtifacts.insert(artifact, at: 0)
        if currentArtifacts.count > 8 {
            currentArtifacts.removeLast(currentArtifacts.count - 8)
        }
        ProjectEventRecorder.ensureArtifact(
            artifact,
            project: project,
            sourceToolRunID: sourceToolRunID,
            context: context
        )
    }

    private func rollbackUnsavedMessage(_ message: ChatMessage, from conversation: Conversation, context: ModelContext) {
        conversation.messages.removeAll { $0.id == message.id }
        message.conversation = nil
        context.delete(message)
        conversation.refreshMessageMetadata()
    }

    private func queueFollowUp(
        _ prompt: String,
        conversation: Conversation,
        context: ModelContext? = nil,
        project: Project? = nil
    ) -> Bool {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        queuedPromptCount = queuedPrompts.count
        guard trimmed.count <= maxQueuedPromptCharacters else {
            setActivity("Follow-up too long", detail: "Wait for the current run to finish, then send the large prompt.")
            pushTrace("Follow-up not queued", detail: "Prompt was over \(maxQueuedPromptCharacters) characters.", status: .failed)
            return false
        }
        guard queuedPrompts.count < maxQueuedPrompts else {
            setActivity("Follow-up queue full", detail: "\(maxQueuedPrompts) follow-ups are already waiting. Pause or let this run finish first.")
            pushTrace("Follow-up not queued", detail: "Queue limit reached: \(maxQueuedPrompts) waiting prompts.", status: .failed)
            return false
        }

        var visibleMessageID: UUID?
        if let context {
            let userMessage = ChatMessage(role: .user, content: prompt, conversation: conversation)
            conversation.appendMessage(userMessage)
            context.insert(userMessage)
            visibleMessageID = userMessage.id
            queuedFollowUpMessageIDs.insert(userMessage.id)
            ProjectEventRecorder.record(
                project: project ?? conversation.project,
                kind: .promptQueued,
                title: "Follow-up queued",
                detail: prompt,
                severity: .running,
                sourceType: .conversation,
                sourceID: conversation.id,
                context: context
            )
            do {
                try saveCompacted(context)
            } catch {
                let message = friendlyError(error)
                presentToast("Follow-up is visible but was not saved yet: \(message)", tone: .error)
                pushTrace("Follow-up save delayed", detail: message, status: .failed)
            }
        }

        queuedPrompts.append(QueuedPrompt(text: prompt, conversation: conversation, visibleMessageID: visibleMessageID))
        queuedPromptCount = queuedPrompts.count
        setActivity("Prompt queued", detail: "\(queuedPromptCount) follow-up\(queuedPromptCount == 1 ? "" : "s") waiting.")
        pushTrace("Follow-up queued", detail: "Waiting for the current run to finish.", status: .queued)
        return true
    }

    private func drainQueueIfPossible(conversation: Conversation, settings: AgentSettings, context: ModelContext) {
        guard !stopRequested, pendingTool == nil, !isWorking else { return }
        guard !queuedPrompts.isEmpty else { return }
        let next = queuedPrompts.removeFirst()
        queuedPromptCount = queuedPrompts.count
        startPrompt(
            next.text,
            conversation: next.conversation,
            settings: settings,
            context: context,
            project: next.conversation.project ?? conversation.project,
            clearsStaleQueuedFollowUps: false,
            origin: .manual,
            visiblePrompt: nil,
            existingVisibleUserMessageID: next.visibleMessageID
        )
    }

    private func discardQueuedPrompts() {
        guard !queuedPrompts.isEmpty || queuedPromptCount != 0 else { return }
        for prompt in queuedPrompts {
            if let messageID = prompt.visibleMessageID {
                queuedFollowUpMessageIDs.remove(messageID)
            }
        }
        queuedPrompts.removeAll()
        queuedPromptCount = 0
    }

    private func responseWithRecovery(
        configuration: ProviderConfiguration,
        messages: [ProviderMessageInput],
        model: String,
        temperature: Double,
        customSystemPrompt: String?,
        workspaceSummary: String,
        runID: UUID,
        onContentBatch: @escaping @MainActor @Sendable (String) -> Void
    ) async throws -> ProviderResponse {
        #if DEBUG || targetEnvironment(simulator)
        if let debugProviderFailure {
            self.debugProviderFailure = nil
            try await streamDebugProviderText(
                "Preparing deterministic failure...",
                onContentBatch: onContentBatch
            )
            throw debugProviderFailure
        }
        if !debugProviderResponses.isEmpty {
            let response = debugProviderResponses.removeFirst()
            if let content = response.message.content,
               !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                try await streamDebugProviderText(content, onContentBatch: onContentBatch)
            }
            return response
        }
        #endif
        var attempt = 0
        while true {
            do {
                return try await AIProviderClient(configuration: configuration).streamingResponse(
                    messages: messages,
                    model: model,
                    temperature: temperature,
                    customSystemPrompt: customSystemPrompt,
                    workspaceSummary: workspaceSummary,
                    onContentBatch: onContentBatch
                )
            } catch {
                attempt += 1
                guard attempt < 3, isRecoverableNetworkError(error), !Task.isCancelled else { throw error }
                try requireActiveRun(runID)
                setActivity("Reconnecting", detail: "Network interrupted. Retry \(attempt) of 2…")
                pushTrace("Connection interrupted", detail: "Retrying automatically.", status: .paused)
                try await Task.sleep(for: .seconds(attempt))
                try requireActiveRun(runID)
            }
        }
    }

    #if DEBUG || targetEnvironment(simulator)
    private func streamDebugProviderText(
        _ text: String,
        onContentBatch: @escaping @MainActor @Sendable (String) -> Void
    ) async throws {
        var index = text.startIndex
        while index < text.endIndex {
            try Task.checkCancellation()
            let end = text.index(index, offsetBy: 24, limitedBy: text.endIndex) ?? text.endIndex
            onContentBatch(String(text[index..<end]))
            index = end
            if index < text.endIndex {
                try await Task.sleep(for: .milliseconds(160))
            }
        }
    }
    #endif

    private func isRecoverableNetworkError(_ error: Error) -> Bool {
        guard let urlError = error as? URLError else { return false }
        return [.networkConnectionLost, .notConnectedToInternet, .timedOut, .cannotConnectToHost, .dnsLookupFailed]
            .contains(urlError.code)
    }

    private func providerHistory(for conversation: Conversation, limit: Int) -> [ProviderMessageInput] {
        var inputs = recentMessages(for: conversation, limit: limit)
            .filter { !queuedFollowUpMessageIDs.contains($0.id) }
            .map(\.providerInput)
        guard let currentPrompt,
              activeConversationID == conversation.id,
              let latestUserIndex = inputs.lastIndex(where: { $0.role == .user }) else {
            return inputs
        }
        let visible = inputs[latestUserIndex]
        inputs[latestUserIndex] = ProviderMessageInput(
            id: visible.id,
            role: visible.role,
            content: currentPrompt,
            createdAt: visible.createdAt,
            toolCallID: visible.toolCallID,
            toolCalls: visible.toolCalls
        )
        return inputs
    }

    private func latestUserPrompt(in conversation: Conversation) -> String? {
        if let currentPrompt, activeConversationID == conversation.id {
            return currentPrompt
        }
        var latest: ChatMessage?
        for message in conversation.messages where message.role == .user {
            guard let current = latest else {
                latest = message
                continue
            }
            if messageAscending(current, message) {
                latest = message
            }
        }
        return latest?.content
    }

    private func orderedMessages(for conversation: Conversation) -> [ChatMessage] {
        conversation.messages.sorted(by: messageAscending)
    }

    private func recentMessages(for conversation: Conversation, limit: Int) -> [ChatMessage] {
        let messages = conversation.messages
        guard limit > 0, !messages.isEmpty else { return [] }
        guard messages.count > limit * 2 else {
            return Array(messages.sorted(by: messageAscending).suffix(limit))
        }

        var newest: [ChatMessage] = []
        newest.reserveCapacity(limit + 1)
        for message in messages {
            newest.append(message)
            guard newest.count > limit else { continue }
            if let oldestIndex = newest.indices.min(by: { lhs, rhs in
                messageAscending(newest[lhs], newest[rhs])
            }) {
                newest.remove(at: oldestIndex)
            }
        }
        return newest.sorted(by: messageAscending)
    }

    private func messageAscending(_ lhs: ChatMessage, _ rhs: ChatMessage) -> Bool {
        if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    private func workspaceSummaryForProvider(_ provider: AIProvider) -> String {
        let items = (try? workspace.manifest(maxItems: provider == .local ? 120 : 500, maxDepth: provider == .local ? 3 : 5)) ?? []
        guard !items.isEmpty else { return "No files yet." }
        let signature = items.map { "\($0.relativePath):\($0.byteCount):\(Int($0.modifiedAt?.timeIntervalSince1970 ?? 0))" }.joined(separator: "|")
        if let cachedWorkspaceSummary, cachedWorkspaceSummary.signature == signature, cachedWorkspaceSummary.provider == provider {
            return cachedWorkspaceSummary.text
        }

        let limit = provider == .local ? 36 : 160
        let paths = items.map { item in
            "\(item.isDirectory ? "folder" : "file"): \(item.relativePath)"
        }
        let visible = paths.prefix(limit).joined(separator: "\n")
        let remaining = max(0, paths.count - limit)
        let text = remaining > 0
            ? "\(visible)\n... \(remaining) more workspace items hidden for responsive provider setup."
            : visible
        cachedWorkspaceSummary = (signature: signature, provider: provider, text: text)
        return text
    }

    private func invalidateWorkspaceSummaryCache() {
        cachedWorkspaceSummary = nil
    }

    private func localResponseWithWatchdog(
        messages: [ProviderMessageInput],
        model: String,
        temperature: Double,
        customSystemPrompt: String?,
        workspaceSummary: String,
        runID: UUID,
        onContentBatch: @escaping @MainActor @Sendable (String) -> Void
    ) async throws -> ProviderResponse {
        try requireActiveRun(runID)
        let variant = LocalModelCatalog.variant(for: model) ?? LocalModelCatalog.defaultVariant
        let safetyTimeoutSeconds = variant.isIPhone12SafeDefault
            ? max(12, variant.maxGenerationSeconds + 6)
            : min(45, max(18, variant.maxGenerationSeconds + 10))
        let timeout: Duration = .seconds(safetyTimeoutSeconds)
        activeLocalModelID = model
        let operation = Task.detached(priority: .utility) { [localModelClient] in
            try await localModelClient.streamingResponse(
                messages: messages,
                model: model,
                temperature: temperature,
                customSystemPrompt: customSystemPrompt,
                workspaceSummary: workspaceSummary,
                onContentBatch: onContentBatch
            )
        }

        let heartbeat = Task { @MainActor [weak self] in
            var elapsed = 0
            while !Task.isCancelled {
                guard let self, self.isActiveRun(runID) else { return }
                self.setActivity(
                    elapsed < variant.maxGenerationSeconds ? "Loading \(variant.shortName)" : "Stopping if needed",
                    detail: "\(variant.executionLabel) · \(elapsed)s elapsed · safety stop at \(safetyTimeoutSeconds)s."
                )
                try? await Task.sleep(for: .seconds(5))
                elapsed += 5
            }
        }

        defer {
            heartbeat.cancel()
            operation.cancel()
            if isActiveRun(runID), activeLocalModelID == model {
                activeLocalModelID = nil
            }
        }

        do {
            return try await withThrowingTaskGroup(of: ProviderResponse.self) { group in
                group.addTask {
                    try await operation.value
                }
                group.addTask { [localModelClient] in
                    try await Task.sleep(for: timeout)
                    operation.cancel()
                    await localModelClient.stop(model: model)
                    throw AgentRuntimeError.localInferenceTimedOut(variant.shortName)
                }

                guard let result = try await group.next() else {
                    throw CancellationError()
                }
                group.cancelAll()
                return result
            }
        } catch {
            operation.cancel()
            await localModelClient.stop(model: model)
            throw error
        }
    }

    private nonisolated static func fastLocalResponseIfNeeded(for prompt: String) -> String? {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()

        // Local mode now runs the on-device model for real prompts instead of
        // brushing them off with a canned "switch to cloud" message. We keep only
        // the explicit test hook and a very high extreme-size guard that would
        // actually destabilize a constrained device; everything else reaches the
        // model so Local behaves like genuine on-device AI.
        if lower.contains("local model is working") {
            return "Local model is working."
        }

        if trimmed.count > 2000 {
            return "This prompt is very long for on-device generation. For the most reliable results on a phone, switch to Zen or OpenAI; Local will still try shorter prompts with the actual model."
        }

        return nil
    }

    private func stopActiveLocalModel() {
        guard let modelID = activeLocalModelID else { return }
        activeLocalModelID = nil
        Task.detached(priority: .userInitiated) { [localModelClient] in
            await localModelClient.stop(model: modelID)
        }
    }

    private func friendlyError(_ error: Error) -> String {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet:
                return "Network unavailable. Reconnect, then tap Retry."
            case .networkConnectionLost:
                return "The network connection was lost. Reconnect, then tap Retry."
            case .timedOut:
                return "The request timed out. Tap Retry to continue."
            case .cancelled:
                return "The request was cancelled. You can send the next message normally."
            default:
                break
            }
        }
        return error.localizedDescription
    }

    private func compactToolDetail(_ request: ToolRequest) -> String {
        let value = request.arguments["path"]
            ?? request.arguments["from"]
            ?? request.arguments["to"]
            ?? request.arguments["query"]
            ?? request.arguments["command"]
            ?? ""
        let line = value.replacingOccurrences(of: "\n", with: " ")
        return line.count > 100 ? String(line.prefix(100)) + "…" : line
    }

    private func compactOutputSummary(_ output: String) -> String {
        let firstLine = output.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? "Tool completed."
        return firstLine.count > 120 ? String(firstLine.prefix(120)) + "…" : firstLine
    }
}

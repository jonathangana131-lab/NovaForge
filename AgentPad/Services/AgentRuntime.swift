import Foundation
import Combine
import Observation
import SwiftData
#if canImport(UIKit)
import UIKit
#endif

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
    case retry
    case continuation
    case autoContinued
}

enum SendRejectionReason: Equatable, Sendable {
    case emptyPrompt
    case anotherConversationIsActive(title: String)
    case followUpTooLong(limit: Int)
    case followUpQueueFull(limit: Int)
    case persistenceFailed(detail: String)

    var userMessage: String {
        switch self {
        case .emptyPrompt:
            return "Write a message before sending."
        case .anotherConversationIsActive(let title):
            return "A response is already running in \(title). Open that chat to add a follow-up."
        case .followUpTooLong(let limit):
            return "This follow-up is over \(limit) characters. Let the active run finish, then send it as a new request."
        case .followUpQueueFull(let limit):
            return "The \(limit)-message follow-up queue is full. Let the active run advance or pause it before trying again."
        case .persistenceFailed:
            return "NovaForge could not save this message. Your draft is still here—free some storage, then try again."
        }
    }
}

enum SendDisposition: Equatable, Sendable {
    case started
    case queued(position: Int)
    case rejected(SendRejectionReason)

    var wasAccepted: Bool {
        switch self {
        case .started, .queued:
            true
        case .rejected:
            false
        }
    }
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

private enum OperationReceiptError: LocalizedError {
    case missing(UUID)

    var errorDescription: String? {
        switch self {
        case .missing(let id):
            "The durable operation receipt \(id.uuidString) could not be found."
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
    /// Provider chunks can arrive in ragged half-words. The Forge engine first
    /// builds a semantic word tree, then reveals whole word/phrase frames on a
    /// steady display cadence so the AI feels like it is speaking instead of
    /// resizing text on every network packet.
    private var activeRevealFrameInterval: Duration {
        // Normal use feels lively; profiling uses a calmer cadence so the gate
        // measures sustained scroll/render health instead of stress-test packet spam.
        AgentPerformance.shouldProfileFrameRate ? .milliseconds(300) : .milliseconds(50)
    }

    // Keep the live bubble as a bounded readable opening + active tail. The
    // final durable assistant message still contains the exact full response;
    // during streaming this avoids re-laying out a giant wall on every frame.
    private var maximumDisplayedCharacters: Int {
        // Normal mode leaves several paragraphs readable. The profiling gate
        // uses a smaller but still comprehensible two-sided window so layout
        // cost remains predictable on the iPhone 12 baseline.
        AgentPerformance.shouldProfileFrameRate ? 540 : 1_200
    }
    @Published private var frame = ForgeLiveFeedFrame.empty
    @Published private var semanticDocument = AIStreamDocument.empty
    @ObservationIgnored private var cachedDisplayFrame = ForgeLiveFeedFrame.empty
    @ObservationIgnored private var feedEngine = ForgeLiveFeedEngine()
    @ObservationIgnored private var semanticEngine = AIStreamDisplayEngine()
    @ObservationIgnored private var revealTask: Task<Void, Never>?
    @ObservationIgnored private var punctuationPauseFrames = 0
    @ObservationIgnored private var revealMetricTickCounter = 0
    @Published private(set) var responseID = UUID()
    @Published private(set) var handoffMessageID: UUID?

    var displayFrame: ForgeLiveFeedFrame {
        cachedDisplayFrame
    }

    var responseDocument: AIStreamDocument { semanticDocument }
    var shouldUseResponseStage: Bool { AIStreamFeatureFlags.responseStageEnabled }

    var displayText: String { displayFrame.displayText }
    var characterCount: Int { frame.characterCount }
    var revision: Int { frame.revision }
    var isEmpty: Bool { frame.characterCount == 0 }
    var isHandoffActive: Bool { handoffMessageID != nil && !isEmpty }
    var isShowingTail: Bool { displayFrame.isShowingTail }
    var revealBacklog: Int { frame.backlogCharacters }

    func reset() {
        revealTask?.cancel()
        revealTask = nil
        feedEngine.reset()
        semanticEngine = AIStreamDisplayEngine(configuration: semanticConfiguration)
        semanticDocument = .empty
        punctuationPauseFrames = 0
        revealMetricTickCounter = 0
        responseID = UUID()
        handoffMessageID = nil
        replaceFrame(.empty)
    }

    func append(_ delta: String) {
        guard !delta.isEmpty else { return }
        feedEngine.ingest(delta)
        if shouldPublishSemanticStream {
            publishSemanticUpdate(semanticEngine.consume(AIStreamEvent(kind: .textDelta(delta))), reason: nil)
        }

        if frame.characterCount == 0 {
            revealNextFrame(forceMinimum: true)
        }
        startRevealLoopIfNeeded()
    }

    /// Legacy/testing escape hatch: reveal everything now.
    func flushPending() {
        revealTask?.cancel()
        revealTask = nil
        if let next = feedEngine.flush() {
            publish(next, reason: "Live Stream Flush")
        }
        if shouldPublishSemanticStream {
            publishSemanticUpdate(semanticEngine.flush(), reason: "AI Stream Flush")
        }
        punctuationPauseFrames = 0
    }

    func finishHandoff(to messageID: UUID) {
        // The provider is done. Freeze the live surface at its last delivered
        // frame and let the durable assistant message replace it as soon as it
        // is rendered. Continuing the reveal loop here used to create a
        // visible "Finishing response" phase that replayed text the user had
        // already watched arrive.
        revealTask?.cancel()
        revealTask = nil
        punctuationPauseFrames = 0
        handoffMessageID = messageID
        if shouldPublishSemanticStream {
            publishSemanticUpdate(semanticEngine.consume(AIStreamEvent(kind: .completed)), reason: "AI Stream Completed")
            publishSemanticUpdate(semanticEngine.flush(), reason: nil)
        }
    }

    func clearHandoffIfRendered(messageID: UUID) {
        guard handoffMessageID == messageID else { return }
        reset()
    }

    private func startRevealLoopIfNeeded() {
        guard revealTask == nil, feedEngine.hasPendingReveal else { return }
        revealTask = Task { @MainActor [weak self] in
            while let self, !Task.isCancelled, self.feedEngine.hasPendingReveal {
                do {
                    try await Task.sleep(for: self.activeRevealFrameInterval)
                } catch {
                    break
                }
                guard !Task.isCancelled else { break }
                if self.punctuationPauseFrames > 0 {
                    self.punctuationPauseFrames -= 1
                } else {
                    self.revealNextFrame(forceMinimum: false)
                    if self.shouldPublishSemanticStream {
                        self.publishSemanticUpdate(self.semanticEngine.tick(), reason: nil)
                    }
                }
            }
            self?.revealTask = nil
        }
    }

    private func revealNextFrame(forceMinimum: Bool) {
        guard let next = feedEngine.revealNextFrame(
            forceMinimum: forceMinimum,
            profileMode: AgentPerformance.shouldProfileFrameRate
        ) else { return }
        punctuationPauseFrames = next.suggestedPauseFrames
        publish(next, reason: nil)
    }

    private func publish(_ next: ForgeLiveFeedFrame, reason: StaticString?) {
        replaceFrame(next)
        revealMetricTickCounter += 1
        if let reason {
            AgentPerformance.event(reason)
        }
        if revealMetricTickCounter.isMultiple(of: 8) || next.backlogCharacters == 0 {
            AgentPerformance.event("Live Feed Word Tree Tick")
            AgentPerformance.value("Live Feed Visible Characters", Double(next.characterCount))
            AgentPerformance.value("Live Feed Visible Atoms", Double(next.visibleAtomCount))
            AgentPerformance.value("Live Feed Backlog Characters", Double(next.backlogCharacters))
        }
    }

    /// Windowing a Swift `String` walks its grapheme clusters. Cache that work
    /// once when a frame is published instead of repeating it for every view
    /// property (`displayText`, `isShowingTail`, and the stage's full frame).
    private func replaceFrame(_ next: ForgeLiveFeedFrame) {
        cachedDisplayFrame = next.windowed(maxCharacters: maximumDisplayedCharacters)
        frame = next
    }

    private var semanticConfiguration: AIStreamDisplayEngine.Configuration {
        AIStreamDisplayEngine.Configuration(
            minimumUpdateInterval: AgentPerformance.shouldProfileFrameRate ? 0.18 : 1.0 / 18.0,
            reducedMotion: !AgentPerformance.allowsDecorativeMotion,
            performanceMode: AgentPerformance.shouldProfileFrameRate,
            maxAnimatedGlyphs: AgentPerformance.shouldProfileFrameRate ? 48 : 96
        )
    }

    private var shouldPublishSemanticStream: Bool {
        AIStreamFeatureFlags.semanticStreamEnabled && !AgentPerformance.shouldProfileFrameRate
    }

    private func publishSemanticUpdate(_ update: AIStreamDisplayUpdate?, reason: StaticString?) {
        guard let update else { return }
        semanticDocument = update.document
        if let reason {
            AgentPerformance.event(reason)
        }
        if update.metrics.emittedSnapshotCount.isMultiple(of: 8) || update.document.isComplete {
            AgentPerformance.event("AI Stream Semantic Tick")
            AgentPerformance.value("AI Stream Characters", Double(update.document.characterCount))
            AgentPerformance.value("AI Stream Suppressed Updates", Double(update.metrics.suppressedUpdateCount))
        }
    }

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
                    projectName: runWorkspace.workspaceName,
                    statusLine: activityTitle == "Ready" ? "Agent run started" : activityTitle
                )
            } else {
                let succeeded = lastError == nil && !wasInterrupted
                if succeeded { NovaHaptics.runSucceeded() } else { NovaHaptics.runFailed() }
                RunActivityController.shared.runEnded(
                    statusLine: lastError ?? activityTitle,
                    success: succeeded
                )
                releaseRunWorkspaceIfSettled()
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

    private(set) var workspace: SandboxWorkspace
    /// The filesystem root is immutable for the lifetime of a run, including
    /// an approval pause. UI navigation may select another project meanwhile,
    /// but summaries, tools, and receipts must continue to use the root that
    /// was captured when the request started.
    private var activeRunWorkspace: SandboxWorkspace?
    private var runWorkspace: SandboxWorkspace { activeRunWorkspace ?? workspace }
    private let keychain = KeychainStore()
    private let localModelClient = LocalModelClient()
    private let executionCoordinator: AgentExecutionCoordinator
    private let maxQueuedPrompts = 3
    private let maxQueuedPromptCharacters = 4_000
    private let maxToolRoundCount = 96
    private var queuedPrompts: [QueuedPrompt] = []
    private var currentTask: Task<Void, Never>?
    private var activeRunID: UUID?
    private var activeRunRecord: AgentRunRecord?
    /// Keeps retry/continuation lineage after the active receipt settles and is
    /// released. The canonical IDs are persisted on the next run record.
    private var lastSettledRunID: UUID?
    private var stopRequested = false
    private var runStartedAt: Date?
    private var currentPrompt: String?
    private var lastRunConversation: Conversation?
    private(set) var activeConversationID: UUID?
    private(set) var activeConversationTitle: String?
    private var pendingApprovalRun: ToolRun?
    private var pendingLocalPlanContinuation: PendingLocalPlanContinuation?
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
        /// The same canonical receipt is promoted to `.running` when this
        /// follow-up drains. It is created in the acceptance transaction, so
        /// an accepted bubble can never be left without durable ownership.
        let durableRun: AgentRunRecord?
        let createdAt = Date()
    }

    private struct DurableRunRollbackState {
        let status: AgentRunStatus
        let projectIDString: String?
        let workspaceName: String?
        let requestMessageIDString: String?
        let providerRawValue: String?
        let modelID: String?
        let errorKindRawValue: String?
        let errorMessage: String?
        let queuedAt: Date?
        let startedAt: Date?
        let updatedAt: Date
        let completedAt: Date?

        init(_ run: AgentRunRecord) {
            status = run.status
            projectIDString = run.projectIDString
            workspaceName = run.workspaceName
            requestMessageIDString = run.requestMessageIDString
            providerRawValue = run.providerRawValue
            modelID = run.modelID
            errorKindRawValue = run.errorKindRawValue
            errorMessage = run.errorMessage
            queuedAt = run.queuedAt
            startedAt = run.startedAt
            updatedAt = run.updatedAt
            completedAt = run.completedAt
        }

        func restore(_ run: AgentRunRecord) {
            run.status = status
            run.projectIDString = projectIDString
            run.workspaceName = workspaceName
            run.requestMessageIDString = requestMessageIDString
            run.providerRawValue = providerRawValue
            run.modelID = modelID
            run.errorKindRawValue = errorKindRawValue
            run.errorMessage = errorMessage
            run.queuedAt = queuedAt
            run.startedAt = startedAt
            run.updatedAt = updatedAt
            run.completedAt = completedAt
        }
    }

    private struct PendingLocalPlanContinuation {
        let remainingCalls: [APIToolCall]
        let completion: String
    }

    init(
        workspace: SandboxWorkspace = SandboxWorkspace(),
        executionCoordinator: AgentExecutionCoordinator = AgentExecutionCoordinator()
    ) {
        self.workspace = workspace
        self.executionCoordinator = executionCoordinator
    }

    private func setLastRunConversation(_ conversation: Conversation?) {
        lastRunConversation = conversation
        activeConversationID = conversation?.id
        let title = conversation?.title.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        activeConversationTitle = title.isEmpty ? nil : title
    }

    #if DEBUG || targetEnvironment(simulator)
    var debugHasTrackedTask: Bool { currentTask != nil }

    func debugInstallPendingApproval(
        request: ToolRequest,
        run: ToolRun,
        conversation: Conversation? = nil
    ) {
        activeRunWorkspace = activeRunWorkspace ?? workspace
        if let conversation {
            setLastRunConversation(conversation)
        }
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
        activeRunWorkspace = workspace
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

        activeRunWorkspace = workspace
        isWorking = true
        runState = .running
        stopRequested = false
        wasInterrupted = false
        liveStream.reset()
        traceEvents = []
        updateActiveTool(name: "response renderer", detail: "Preparing a readable live answer")
        setActivity("Forge live response", detail: "Writing with a steady, readable cadence.")
        pushTrace("Live response started", detail: "The incoming response is being smoothed into readable phrases.", status: .thinking)

        let script = Array(repeating: Self.forgeLiveFeedStressScript, count: 16).joined(separator: "\n\n")
        let chunks = Self.raggedProviderChunks(from: script)
        let runID = beginRunIdentity()
        currentTask = Task { [weak self] in
            guard let self else { return }
            defer { self.clearCurrentTaskIfActive(runID) }
            for (offset, chunk) in chunks.enumerated() {
                guard !Task.isCancelled, !self.stopRequested else { return }
                let index = offset + 1
                if index == 1 || index.isMultiple(of: 44) {
                    self.updateActiveTool(name: "response renderer", detail: "Organizing the response")
                }
                self.liveStream.append(chunk)
                if index == 1 || index.isMultiple(of: 88) {
                    self.pushTrace("Live response progress", detail: "Keeping the live response readable.", status: .thinking)
                }
                try? await Task.sleep(for: .milliseconds(index.isMultiple(of: 9) ? 34 : 16))
            }

            guard !Task.isCancelled, !self.stopRequested else { return }
            self.liveStream.finishHandoff(to: UUID())
            self.setActivity("Live response complete", detail: "The full answer is ready to review.")
            self.pushTrace("Live response complete", detail: "\(chunks.count) provider chunks became readable live frames.", status: .success)
            self.runState = .completed
            self.isWorking = false
            self.clearActiveTool()
        }
    }

    private static let forgeLiveFeedStressScript = """
    NovaForge is speaking through the new Forge live feed. The provider can send half words, weird punctuation, dense technical notes, and sudden pauses, but the phone should only see calm semantic phrases.

    First the engine groups the response into readable phrases. Then it reveals stable milestones on a display-paced clock. Old text becomes settled ink, the active phrase glows softly, and the transcript keeps the bottom response readable above the composer.

    This fixture intentionally uses jagged chunks so the live answer stays smooth through the roughest AI stream without jitter, duplicate bubbles, or sudden jumps.
    """

    private static func raggedProviderChunks(from text: String) -> [String] {
        let pattern = [3, 1, 9, 2, 17, 4, 6, 1, 23, 5, 8, 2, 14, 7]
        var chunks: [String] = []
        var index = text.startIndex
        var patternIndex = 0
        while index < text.endIndex {
            let length = pattern[patternIndex % pattern.count]
            let end = text.index(index, offsetBy: length, limitedBy: text.endIndex) ?? text.endIndex
            chunks.append(String(text[index..<end]))
            index = end
            patternIndex += 1
        }
        return chunks
    }

    func debugSimulateDelayedCompletionForActiveRun(delayMilliseconds: UInt64 = 120) {
        guard !isWorking, pendingTool == nil else { return }
        activeRunWorkspace = workspace
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

    @discardableResult
    func switchWorkspace(to name: String) -> Bool {
        let safeName = SandboxWorkspace.sanitizedWorkspaceName(name)
        guard !isWorking, pendingTool == nil, runState != .waitingForApproval else {
            return false
        }
        // Terminal/debug fixtures can settle without a durable receipt callback.
        // Once the safety guard above passes, no run still owns the capture.
        activeRunWorkspace = nil
        if workspace.workspaceName != safeName {
            invalidateWorkspaceSummaryCache()
            self.workspace = SandboxWorkspace(name: safeName)
            ensureSeedWorkspace()
        }
        return true
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

    @discardableResult
    func send(
        prompt: String,
        conversation: Conversation,
        settings: AgentSettings,
        context: ModelContext,
        project: Project? = nil,
        origin: AgentRunOrigin = .manual,
        visiblePrompt: String? = nil
    ) -> SendDisposition {
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .rejected(.emptyPrompt)
        }
        if isWorking || pendingTool != nil {
            if let activeConversationID, activeConversationID != conversation.id {
                let title = activeConversationTitle?.isEmpty == false ? activeConversationTitle! : "another chat"
                let reason = SendRejectionReason.anotherConversationIsActive(title: title)
                presentToast(reason.userMessage, tone: .info)
#if canImport(UIKit)
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
#endif
                return .rejected(reason)
            }
            let disposition = queueFollowUp(
                prompt,
                conversation: conversation,
                context: context,
                project: project ?? conversation.project,
                settings: settings
            )
            if disposition.wasAccepted {
#if canImport(UIKit)
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
#endif
            }
            return disposition
        }

        return startPrompt(
            prompt,
            conversation: conversation,
            settings: settings,
            context: context,
            project: project,
            origin: origin,
            visiblePrompt: visiblePrompt
        )
    }

    func retryLastPrompt(conversation: Conversation, settings: AgentSettings, context: ModelContext, project: Project? = nil) {
        guard let lastFailedPrompt else { return }
        let targetConversation = lastRunConversation ?? conversation
        clearCurrentRunState(keepLastFailure: false)
        send(
            prompt: lastFailedPrompt,
            conversation: targetConversation,
            settings: settings,
            context: context,
            project: project,
            origin: .retry
        )
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
            project: project,
            origin: .continuation
        )
    }

    func stopGenerating(context: ModelContext? = nil) {
        let stoppedRunID = activeRunRecord?.id
        let stoppedConversation = lastRunConversation
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
#if canImport(UIKit)
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
#endif
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
        pendingLocalPlanContinuation = nil
        discardQueuedPrompts(context: context, terminalStatus: .cancelled)
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
            if let stoppedRunID, let stoppedConversation {
                persistActiveRunRecordState(
                    runID: stoppedRunID,
                    conversation: stoppedConversation,
                    context: context
                )
            }
        }
#if canImport(UIKit)
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
#endif
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
        pendingLocalPlanContinuation = nil
        activeRunWorkspace = nil
        setLastRunConversation(nil)
    }

    @discardableResult
    func reconcileInterruptedDurableWork(context: ModelContext, now: Date = Date()) -> Int {
        let scheduledPhase = ToolOperationPhase.scheduled.rawValue
        let executingPhase = ToolOperationPhase.executing.rawValue
        let appliedPhase = ToolOperationPhase.applied.rawValue
        let queuedStatus = AgentRunStatus.queued.rawValue
        let runningStatus = AgentRunStatus.running.rawValue
        let awaitingStatus = AgentRunStatus.awaitingApproval.rawValue
        let operationDescriptor = FetchDescriptor<ToolOperationRecord>(
            predicate: #Predicate {
                $0.phaseRawValue == scheduledPhase ||
                    $0.phaseRawValue == executingPhase ||
                    $0.phaseRawValue == appliedPhase
            }
        )
        let runDescriptor = FetchDescriptor<AgentRunRecord>(
            predicate: #Predicate {
                $0.statusRawValue == queuedStatus ||
                    $0.statusRawValue == runningStatus ||
                    $0.statusRawValue == awaitingStatus
            }
        )
        let unfinishedOperations: [ToolOperationRecord]
        let unfinishedRuns: [AgentRunRecord]
        do {
            unfinishedOperations = try context.fetch(operationDescriptor)
            unfinishedRuns = try context.fetch(runDescriptor)
        } catch {
            presentToast("NovaForge could not inspect interrupted work: \(friendlyError(error))", tone: .error)
            return 0
        }
        for operation in unfinishedOperations {
            let previousPhase = operation.phase
            let recoveryDetail: String
            switch previousPhase {
            case .scheduled:
                recoveryDetail = "NovaForge closed before the workspace mutation started."
            case .executing:
                recoveryDetail = "NovaForge closed while this mutation was executing. Inspect the target before retrying."
            case .applied:
                recoveryDetail = "The mutation was applied, but its final receipt was interrupted. Inspect the target before retrying."
            case .completed, .failed, .interrupted:
                continue
            }
            operation.transition(to: .interrupted, at: now, errorMessage: recoveryDetail)
            // A scheduled mutation never began. ToolOperationRecord.transition
            // normally initializes startedAt for any non-scheduled destination,
            // so preserve the stronger write-ahead fact during recovery.
            if previousPhase == .scheduled {
                operation.startedAt = nil
            }
        }

        for record in unfinishedRuns {
            let previousStatus = record.status
            record.transition(
                to: .interrupted,
                at: now,
                errorKind: .interrupted,
                errorMessage: "The app closed before this run reached a durable terminal state."
            )
            if previousStatus == .queued {
                record.startedAt = nil
            }

            // Interrupted work is normally one run. Query only its scalar links
            // instead of scanning the user's entire transcript at every launch.
            let runIDString = record.id.uuidString
            let messageDescriptor = FetchDescriptor<ChatMessage>(
                predicate: #Predicate { $0.runIDString == runIDString }
            )
            let toolRunDescriptor = FetchDescriptor<ToolRun>(
                predicate: #Predicate { $0.runIDString == runIDString }
            )
            stampRunTimeline(
                record: record,
                messages: (try? context.fetch(messageDescriptor)) ?? [],
                toolRuns: (try? context.fetch(toolRunDescriptor)) ?? [],
                status: .interrupted
            )
        }

        let repairedCount = unfinishedOperations.count + unfinishedRuns.count
        guard repairedCount > 0 else { return 0 }
        do {
            try context.save()
            if !unfinishedOperations.isEmpty, !unfinishedRuns.isEmpty {
                presentToast(
                    "Recovered \(unfinishedOperations.count) interrupted workspace receipt\(unfinishedOperations.count == 1 ? "" : "s") and \(unfinishedRuns.count) interrupted run\(unfinishedRuns.count == 1 ? "" : "s"). Review the affected paths before retrying.",
                    tone: .info
                )
            } else if !unfinishedOperations.isEmpty {
                presentToast(
                    "Recovered \(unfinishedOperations.count) interrupted workspace receipt\(unfinishedOperations.count == 1 ? "" : "s"). Review the affected paths before retrying.",
                    tone: .info
                )
            } else if !unfinishedRuns.isEmpty {
                presentToast(
                    "Recovered \(unfinishedRuns.count) interrupted run\(unfinishedRuns.count == 1 ? "" : "s"). Continue from the saved transcript when you are ready.",
                    tone: .info
                )
            }
        } catch {
            presentToast("NovaForge could not save interrupted-run recovery: \(friendlyError(error))", tone: .error)
            return 0
        }
        return repairedCount
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
    ) -> SendDisposition {
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
        existingVisibleUserMessageID: UUID?,
        existingQueuedRun: AgentRunRecord? = nil
    ) -> SendDisposition {
        let activeProject = project ?? conversation.project
        let previousConversationProject = conversation.project
        let previousConversationUpdatedAt = conversation.updatedAt
        let previousConversationMessageCount = conversation.messageCount
        let previousConversationPreview = conversation.lastMessagePreview
        let previousConversationHasUserMessages = conversation.hasUserMessages
        if conversation.project == nil {
            conversation.project = activeProject
        }
        let displayedPrompt = visiblePrompt?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? visiblePrompt! : prompt
        let visibleUserMessage: ChatMessage
        let insertedVisibleUserMessage: Bool
        var previousVisibleMessageContent: String?
        var previousVisibleMessageConversation: Conversation?
        var previousVisibleMessageRunID: UUID?
        var previousVisibleMessageRunSequence: Int?
        var previousVisibleMessageRunStatus: AgentRunStatus?
        if let existingVisibleUserMessageID,
           let existing = conversation.messages.first(where: { $0.id == existingVisibleUserMessageID }) {
            previousVisibleMessageContent = existing.content
            previousVisibleMessageConversation = existing.conversation
            previousVisibleMessageRunID = existing.runID
            previousVisibleMessageRunSequence = existing.runSequence
            previousVisibleMessageRunStatus = existing.runStatus
            existing.content = PersistedPayloadBudget.compactMessageContent(displayedPrompt, role: .user)
            existing.conversation = conversation
            visibleUserMessage = existing
            insertedVisibleUserMessage = false
            conversation.refreshMessageMetadata(updateTimestamp: Date())
        } else {
            let userMessage = ChatMessage(role: .user, content: displayedPrompt, conversation: conversation)
            conversation.appendMessage(userMessage)
            context.insert(userMessage)
            visibleUserMessage = userMessage
            insertedVisibleUserMessage = true
        }

        let runStartedAt = Date()
        let durableRun: AgentRunRecord
        let insertedDurableRun: Bool
        let queuedRunRollbackState: DurableRunRollbackState?
        if let existingQueuedRun {
            durableRun = existingQueuedRun
            insertedDurableRun = false
            queuedRunRollbackState = DurableRunRollbackState(existingQueuedRun)
            existingQueuedRun.projectIDString = activeProject?.id.uuidString
            existingQueuedRun.workspaceName = workspace.workspaceName
            existingQueuedRun.requestMessageIDString = visibleUserMessage.id.uuidString
            existingQueuedRun.provider = settings.provider
            existingQueuedRun.modelID = settings.modelID
            existingQueuedRun.transition(to: .running, at: runStartedAt)
        } else {
            let runID = UUID()
            durableRun = AgentRunRecord(
                id: runID,
                status: .running,
                origin: persistentOrigin(for: origin),
                conversationID: conversation.id,
                projectID: activeProject?.id,
                workspaceName: workspace.workspaceName,
                requestMessageID: visibleUserMessage.id,
                provider: settings.provider,
                modelID: settings.modelID,
                retryOfRunID: origin == .retry ? lastSettledRunID : nil,
                continuationOfRunID: origin == .continuation ? lastSettledRunID : nil,
                now: runStartedAt
            )
            insertedDurableRun = true
            queuedRunRollbackState = nil
            context.insert(durableRun)
        }
        let runID = durableRun.id
        visibleUserMessage.runID = runID
        visibleUserMessage.runSequence = 0
        visibleUserMessage.runStatus = .running

        // The acceptance boundary is deliberately synchronous: Chat may clear
        // its draft only after both the visible user turn and canonical run
        // receipt have committed. No provider or tool task exists before this
        // save succeeds.
        do {
            try saveAcceptanceBoundary(context)
        } catch {
            if insertedDurableRun {
                context.delete(durableRun)
            } else if let queuedRunRollbackState {
                queuedRunRollbackState.restore(durableRun)
            }
            if insertedVisibleUserMessage {
                rollbackUnsavedMessage(visibleUserMessage, from: conversation, context: context)
            } else {
                visibleUserMessage.content = previousVisibleMessageContent ?? visibleUserMessage.content
                visibleUserMessage.conversation = previousVisibleMessageConversation
                visibleUserMessage.runID = previousVisibleMessageRunID
                visibleUserMessage.runSequence = previousVisibleMessageRunSequence
                visibleUserMessage.runStatus = previousVisibleMessageRunStatus
            }
            conversation.project = previousConversationProject
            conversation.updatedAt = previousConversationUpdatedAt
            conversation.messageCount = previousConversationMessageCount
            conversation.lastMessagePreview = previousConversationPreview
            conversation.hasUserMessages = previousConversationHasUserMessages

            let detail = friendlyError(error)
            let reason = SendRejectionReason.persistenceFailed(detail: detail)
            presentToast(reason.userMessage, tone: .error)
            return .rejected(reason)
        }

        // A successful receipt owns this queued message now. Remove its queue
        // marker only after the receipt commit so a failed drain can retry the
        // exact already-persisted item.
        if let existingVisibleUserMessageID {
            queuedFollowUpMessageIDs.remove(existingVisibleUserMessageID)
        }
        if clearsStaleQueuedFollowUps, !queuedPrompts.isEmpty {
            // Debug/legacy in-memory prompts have no durable bubble or receipt
            // to protect. Drop only those stale transient entries before a
            // fresh explicit send; persisted follow-ups remain in order and
            // will drain after this run.
            queuedPrompts.removeAll { $0.durableRun == nil && $0.visibleMessageID == nil }
            queuedPromptCount = queuedPrompts.count
        }

        activeRunWorkspace = workspace
        isWorking = true
        runState = .running
        stopRequested = false
        wasInterrupted = false
        self.runStartedAt = runStartedAt
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

        activeRunRecord = durableRun
        _ = beginRunIdentity(runID)
        applyProjectIdentitySuggestionIfNeeded(
            to: activeProject,
            conversation: conversation,
            prompt: prompt,
            context: context
        )
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
        currentTask = Task {
            defer { clearCurrentTaskIfActive(runID) }
            await runAgentLoop(
                conversation: conversation,
                settings: settings,
                context: context,
                runID: runID,
                project: activeProject,
                origin: origin
            )
            persistActiveRunRecordState(runID: runID, conversation: conversation, context: context)
        }
        return .started
    }

    func approvePendingTool(conversation: Conversation, settings: AgentSettings, context: ModelContext, project: Project? = nil) {
        guard let request = pendingTool else { return }
        let targetConversation = lastRunConversation ?? conversation
        // Approval belongs to the paused run, not whichever project happens to
        // be selected in the UI when the user presses Approve.
        let activeProject = pendingApprovalRun?.project ?? targetConversation.project ?? project
        let approvalRun = pendingApprovalRun
        let localPlanContinuation = pendingLocalPlanContinuation
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
                // ProjectEventRecorder also touches the project ledger. A
                // field-by-field ToolRun restore is not enough: roll the
                // entire decision transaction back so a later save cannot
                // manufacture an "Approved" audit receipt.
                context.rollback()
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

        let runID = beginRunIdentity(activeRunRecord?.id)
        currentTask = Task {
            defer { clearCurrentTaskIfActive(runID) }
            let output = await executeTool(request, context: context, project: activeProject, recordRun: false)
            guard isActiveRun(runID) else { return }
            let previousRunStatus = approvalRun?.status
                let previousRunOutput = approvalRun?.output
                let previousRunCompletedAt = approvalRun?.completedAt
                var toolMsg: ChatMessage?
                do {
                    let persistedRun = finishApprovalRun(
                        approvalRun,
                        request: request,
                        output: output,
                        status: output.hasPrefix("Error:") ? .failed : .completed,
                        project: activeProject,
                        context: context
                    )
                    rememberArtifact(from: output, project: activeProject, sourceToolRunID: persistedRun.id, context: context)
                    if request.isMutating {
                        invalidateWorkspaceSummaryCache()
                    }
                    let message = ChatMessage(
                        role: .tool,
                        content: output,
                        toolCallID: request.id,
                        conversation: targetConversation,
                        runID: activeRunRecord?.id ?? activeRunID,
                        runStatus: .running
                    )
                    toolMsg = message
                    targetConversation.appendMessage(message)
                    context.insert(message)
                    try saveCompacted(context)
                } catch {
                    // The workspace may already have changed, but its receipt
                    // must be all-or-nothing. Roll back every unsaved event,
                    // ledger mutation, file record, and tool message before
                    // exposing the recovery state.
                    context.rollback()
                    if let approvalRun {
                        if let previousRunStatus {
                            approvalRun.status = previousRunStatus
                        }
                        if let previousRunOutput {
                            approvalRun.output = previousRunOutput
                        }
                        approvalRun.completedAt = previousRunCompletedAt
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
                    discardQueuedPrompts(context: context)
                    isWorking = false
                    runState = .failed(message)
                    setActivity(
                        "Tool Result Not Saved",
                        detail: "NovaForge ran \(request.name), but could not save the tool result. Check storage and retry from the current workspace state."
                    )
                    pushTrace("Tool result not saved", detail: message, status: .failed)
                    persistActiveRunRecordState(runID: runID, conversation: targetConversation, context: context)
                    return
                }

            if let localPlanContinuation {
                pendingLocalPlanContinuation = nil
                do {
                    let completed: Bool
                    if localPlanContinuation.remainingCalls.isEmpty {
                        completed = try finishLocalPlanCompletion(
                            localPlanContinuation.completion,
                            conversation: targetConversation,
                            context: context,
                            project: activeProject
                        )
                    } else {
                        completed = try await runLocalNativePlan(
                            LocalAgentPlan(
                                intro: "Approved. I’ll continue the remaining local actions safely.",
                                toolCalls: localPlanContinuation.remainingCalls,
                                completion: localPlanContinuation.completion
                            ),
                            conversation: targetConversation,
                            context: context,
                            runID: runID,
                            project: activeProject,
                            autoApproveWrites: false
                        )
                    }
                    guard isActiveRun(runID) else { return }
                    if completed {
                        drainQueueIfPossible(conversation: targetConversation, settings: settings, context: context)
                    } else if pendingTool == nil {
                        discardQueuedPrompts(context: context)
                    }
                } catch {
                    guard isActiveRun(runID) else { return }
                    let message = friendlyError(error)
                    lastError = message
                    lastFailedPrompt = latestUserPrompt(in: targetConversation)
                    isWorking = false
                    runState = .failed(message)
                    setActivity("Local continuation failed", detail: message)
                    pushTrace("Local continuation failed", detail: message, status: .failed)
                    saveCompactedIfPossible(context)
                }
                persistActiveRunRecordState(runID: runID, conversation: targetConversation, context: context)
                return
            }

            await runAgentLoop(
                conversation: targetConversation,
                settings: settings,
                context: context,
                runID: runID,
                project: activeProject
            )
            persistActiveRunRecordState(runID: runID, conversation: targetConversation, context: context)
        }
    }

    func rejectPendingTool(conversation: Conversation, settings: AgentSettings, context: ModelContext, project: Project? = nil) {
        guard let request = pendingTool else { return }
        let targetConversation = lastRunConversation ?? conversation
        let activeProject = pendingApprovalRun?.project ?? targetConversation.project ?? project
        let approvalRun = pendingApprovalRun
        let previousRunStatus = approvalRun?.status
        let previousRunOutput = approvalRun?.output
        let previousRunCompletedAt = approvalRun?.completedAt
        runStartedAt = runStartedAt ?? Date()
        isWorking = true
        runState = .running

        let runID = beginRunIdentity(activeRunRecord?.id)
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
                    conversation: targetConversation,
                    runID: activeRunRecord?.id ?? activeRunID,
                    runStatus: .running
                )
                rejectionToolMessage = toolMsg
                targetConversation.appendMessage(toolMsg)
                context.insert(toolMsg)
                try saveCompacted(context)

                pendingApprovalRun = nil
                pendingTool = nil
                pendingLocalPlanContinuation = nil
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
                // `finishApprovalRun` records project events and updates the
                // ledger. Roll all of that back before restoring the pending
                // decision so a later save cannot create a false rejection.
                context.rollback()
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
                    rollbackUnsavedMessage(rejectionToolMessage, from: targetConversation, context: context)
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
            persistActiveRunRecordState(runID: runID, conversation: targetConversation, context: context)
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
                    conversation: conversation,
                    runID: activeRunRecord?.id ?? activeRunID,
                    runStatus: .failed
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
                discardQueuedPrompts(context: context)
                runStartedAt = nil
                currentPrompt = nil
                try saveCompacted(context)
                return
            }

            if runProvider == .local,
               orderedMessages(for: conversation).last?.role == .user,
               let latestPrompt = latestUserPrompt(in: conversation),
               let localPlan = LocalAgentPlanner.plan(prompt: latestPrompt, workspace: runWorkspace) {
                let completedLocalPlan = try await runLocalNativePlan(
                    localPlan,
                    conversation: conversation,
                    context: context,
                    runID: runID,
                    project: activeProject,
                    autoApproveWrites: runAutoApproveWrites
                )
                guard isActiveRun(runID) else { return }
                if completedLocalPlan {
                    drainQueueIfPossible(conversation: conversation, settings: settings, context: context)
                } else if pendingTool == nil {
                    discardQueuedPrompts(context: context)
                }
                return
            }

            if runProvider == .local,
               let latestPrompt = latestUserPrompt(in: conversation),
               let responseText = Self.fastLocalResponseIfNeeded(for: latestPrompt) {
                setActivity("Local mode is safe", detail: "Short local fallback keeps iPhone 12 responsive.")
                await showImmediateResponse(responseText)
                guard isActiveRun(runID) else { return }
                let assistant = ChatMessage(
                    id: liveStream.responseID,
                    role: .assistant,
                    content: responseText,
                    conversation: conversation,
                    runID: activeRunRecord?.id ?? activeRunID,
                    runStatus: .running
                )
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
                    // The response event and project ledger mutation are part
                    // of the same persistence boundary as the assistant
                    // bubble. Do not let them hitch a ride on the later failed
                    // run receipt save.
                    context.rollback()
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

                let rawHistory = providerHistory(for: conversation, limit: 96)
                let contextBudget: ProviderContextWindow.Budget
                if runProvider == .local {
                    let variant = LocalModelCatalog.variant(for: runModelID) ?? LocalModelCatalog.defaultVariant
                    contextBudget = .local(contextTokens: Int(variant.contextTokens))
                } else {
                    contextBudget = .hosted
                }
                let history = ProviderContextWindow.select(rawHistory, budget: contextBudget)
                AgentPerformance.value("Provider Context Messages", Double(history.count))
                AgentPerformance.value(
                    "Provider Context Estimated Tokens",
                    Double(ProviderContextWindow.estimatedTokenCount(history))
                )
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
                        conversation: conversation,
                        runID: activeRunRecord?.id ?? activeRunID,
                        runStatus: .running
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
                                project: activeProject,
                                runID: activeRunRecord?.id ?? activeRunID,
                                runStatus: .awaitingApproval
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
                                conversation: conversation,
                                runID: activeRunRecord?.id ?? activeRunID,
                                runStatus: .running
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
                        // ToolOperationRecord write-ahead receipts are saved
                        // in their own context. Everything in this history
                        // context is still one transcript transaction and must
                        // disappear together before the failed run receipt is
                        // persisted below.
                        context.rollback()
                        for message in toolMessages.reversed() {
                            rollbackUnsavedMessage(message, from: conversation, context: context)
                        }
                        for artifact in rememberedArtifacts {
                            currentArtifacts.removeAll { $0.id == artifact.id }
                        }
                        let message = friendlyError(error)
                        lastError = message
                        lastFailedPrompt = latestUserPrompt(in: conversation)
                        discardQueuedPrompts(context: context)
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
                    conversation: conversation,
                    runID: activeRunRecord?.id ?? activeRunID,
                    runStatus: .running
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
                    // The final response is not durable until its event and
                    // ledger update save too. Roll back all three before the
                    // outer failure path creates a truthful failed receipt.
                    context.rollback()
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
            // A provider/local failure can arrive immediately after a failed
            // transcript save. Clear every pending model mutation before this
            // recovery path records its own failure event; otherwise a later
            // unrelated save could preserve false success evidence.
            context.rollback()
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
                discardQueuedPrompts(context: context)
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
                    conversation: conversation,
                    runID: activeRunRecord?.id ?? activeRunID,
                    runStatus: .interrupted
                )
                conversation.appendMessage(assistant)
                context.insert(assistant)
                runState = .cancelled
                discardQueuedPrompts(context: context)
                do {
                    try saveCompacted(context)
                } catch {
                    context.rollback()
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
                discardQueuedPrompts(context: context)
                let assistant = ChatMessage(
                    role: .assistant,
                    content: "I hit an error: \(message)",
                    conversation: conversation,
                    runID: activeRunRecord?.id ?? activeRunID,
                    runStatus: .failed
                )
                conversation.appendMessage(assistant)
                context.insert(assistant)
                do {
                    try saveCompacted(context)
                } catch {
                    context.rollback()
                    rollbackUnsavedMessage(assistant, from: conversation, context: context)
                    let saveMessage = friendlyError(error)
                    // Keep the original run failure actionable. A second
                    // persistence failure can explain why the visible error
                    // bubble was not saved, but it must not erase the cause
                    // that actually stopped the run.
                    lastError = message
                    setActivity(
                        "Error Not Saved",
                        detail: "\(message) NovaForge could not save the error transcript either: \(saveMessage)"
                    )
                    pushTrace("Error transcript not saved", detail: "\(message) · \(saveMessage)", status: .failed)
                    runState = .failed(message)
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
        var operationRecordID: UUID?
        if request.isMutating {
            do {
                // The write-ahead receipt has to commit before a workspace
                // mutation, but it must not flush the provider transcript
                // transaction that is still accumulating in `context`.
                // A dedicated context keeps the safety receipt durable without
                // turning a later tool-result save failure into partial history.
                operationRecordID = try createOperationReceipt(
                    for: request,
                    project: project,
                    context: context
                )
            } catch {
                let message = friendlyError(error)
                presentToast("NovaForge did not run \(request.name) because its safety receipt could not be saved: \(message)", tone: .error)
                return "Error: safety receipt could not be saved before mutation: \(message)"
            }
        }

        var mutationLease: AgentExecutionCoordinator.Lease?
        defer {
            // The defer is installed before any post-acquisition receipt save.
            // Otherwise a failed `.executing` save could strand the shared
            // workspace lease and block every later mutation in this workspace.
            if let mutationLease {
                Task { await executionCoordinator.release(mutationLease) }
            }
        }
        if request.isMutating {
            setActivity("Coordinating workspace", detail: "Waiting for exclusive access to \(runWorkspace.workspaceName).")
            do {
                mutationLease = try await executionCoordinator.acquireMutation(
                    workspaceName: runWorkspace.workspaceName,
                    runID: activeRunRecord?.id ?? activeRunID ?? UUID(),
                    ownerDescription: activeConversationTitle ?? project?.name ?? runWorkspace.workspaceName
                )
            } catch is CancellationError {
                if let operationRecordID {
                    try? transitionOperationReceipt(
                        id: operationRecordID,
                        to: .interrupted,
                        errorMessage: "Cancelled while waiting for exclusive workspace access.",
                        context: context
                    )
                }
                return "Error: tool cancelled while waiting for workspace access."
            } catch {
                if let operationRecordID {
                    try? transitionOperationReceipt(
                        id: operationRecordID,
                        to: .failed,
                        errorMessage: error.localizedDescription,
                        context: context
                    )
                }
                return "Error: could not coordinate workspace access: \(error.localizedDescription)"
            }

            guard let operationRecordID else {
                return "Error: safety receipt was unavailable before mutation."
            }
            do {
                try transitionOperationReceipt(
                    id: operationRecordID,
                    to: .executing,
                    context: context
                )
            } catch {
                let message = friendlyError(error)
                try? transitionOperationReceipt(
                    id: operationRecordID,
                    to: .failed,
                    errorMessage: "Execution did not start because its durable receipt could not advance: \(message)",
                    context: context
                )
                presentToast("NovaForge did not run \(request.name) because its execution receipt could not be advanced: \(message)", tone: .error)
                return "Error: execution receipt could not be advanced before mutation: \(message)"
            }
        }

        let workspace = runWorkspace
        let task = Task.detached(priority: .userInitiated) {
            do {
                try Task.checkCancellation()
                let output = try SandboxToolExecutor(workspace: workspace).execute(request)
                // Once a mutation has entered the executor, cancellation cannot
                // prove that no bytes changed. Always return its concrete result
                // so the write-ahead receipt advances to applied/completed.
                if !request.isMutating {
                    try Task.checkCancellation()
                }
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

        if let operationRecordID {
            do {
                if result.1 == .completed {
                    try transitionOperationReceipt(
                        id: operationRecordID,
                        to: .applied,
                        resultSummary: output,
                        context: context
                    )
                    try transitionOperationReceipt(
                        id: operationRecordID,
                        to: .completed,
                        resultSummary: output,
                        context: context
                    )
                } else {
                    try transitionOperationReceipt(
                        id: operationRecordID,
                        to: .failed,
                        errorMessage: output,
                        context: context
                    )
                }
            } catch {
                let message = friendlyError(error)
                if result.1 == .completed {
                    // Keep the recoverable state honest if a later caller save
                    // succeeds after this phase-specific save failed.
                    try? transitionOperationReceipt(
                        id: operationRecordID,
                        to: .applied,
                        resultSummary: output,
                        context: context
                    )
                }
                presentToast(
                    "\(request.name) finished, but NovaForge could not finalize its durable receipt. Review the workspace before retrying: \(message)",
                    tone: .error
                )
                pushTrace("Operation receipt incomplete", detail: message, status: .failed)
                return "Error: tool may have changed the workspace, but its durable receipt did not finish: \(message)"
            }
        }

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

    /// Persists write-ahead mutation receipts without committing whatever chat
    /// transcript, evidence, and project-ledger work is still pending in the
    /// caller's context. `ToolOperationRecord` is scalar-only by design, so a
    /// short-lived context can own this isolated safety transaction.
    private func createOperationReceipt(
        for request: ToolRequest,
        project: Project?,
        context: ModelContext
    ) throws -> UUID {
        let receiptContext = ModelContext(context.container)
        receiptContext.autosaveEnabled = false
        let record = ToolOperationRecord(
            runID: activeRunRecord?.id ?? activeRunID,
            projectID: project?.id,
            conversationID: activeConversationID,
            workspaceName: runWorkspace.workspaceName,
            toolCallID: request.id,
            toolName: request.name,
            argumentsJSON: request.argumentsJSON,
            targetPaths: operationTargetPaths(for: request)
        )
        receiptContext.insert(record)
        try receiptContext.save()
        return record.id
    }

    private func transitionOperationReceipt(
        id: UUID,
        to phase: ToolOperationPhase,
        resultSummary: String? = nil,
        errorMessage: String? = nil,
        context: ModelContext
    ) throws {
        let receiptContext = ModelContext(context.container)
        receiptContext.autosaveEnabled = false
        let descriptor = FetchDescriptor<ToolOperationRecord>(predicate: #Predicate { $0.id == id })
        guard let record = try receiptContext.fetch(descriptor).first else {
            throw OperationReceiptError.missing(id)
        }
        record.transition(
            to: phase,
            resultSummary: resultSummary,
            errorMessage: errorMessage
        )
        try receiptContext.save()
    }

    private func operationTargetPaths(for request: ToolRequest) -> [String] {
        var seen = Set<String>()
        return ["path", "from", "to", "cwd"]
            .compactMap { request.arguments[$0]?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
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
            run.runID = run.runID ?? activeRunRecord?.id ?? activeRunID
            run.runStatus = activeRunRecord?.status ?? .running
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
            project: project,
            runID: activeRunRecord?.id ?? activeRunID,
            runStatus: activeRunRecord?.status ?? .running
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
            workspaceName: runWorkspace.workspaceName,
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
                "workspace": runWorkspace.workspaceName,
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
        project: Project?,
        autoApproveWrites: Bool
    ) async throws -> Bool {
        guard isActiveRun(runID) else { return false }
        let activeProject = project ?? conversation.project
        let firstApprovalIndex = autoApproveWrites
            ? nil
            : plan.toolCalls.firstIndex(where: { call in
                ToolRequest(
                    id: call.id,
                    name: call.function.name,
                    arguments: parseArguments(call.function.arguments)
                ).isMutating
            })
        let stageCalls: [APIToolCall]
        let remainingCalls: [APIToolCall]
        if let firstApprovalIndex {
            stageCalls = Array(plan.toolCalls.prefix(through: firstApprovalIndex))
            remainingCalls = Array(plan.toolCalls.dropFirst(firstApprovalIndex + 1))
        } else {
            stageCalls = plan.toolCalls
            remainingCalls = []
        }
        liveStream.reset()
        setActivity("Planning local tools", detail: "\(stageCalls.count) native action\(stageCalls.count == 1 ? "" : "s") ready.")
        pushTrace("Local tool plan ready", detail: stageCalls.map { $0.function.name }.joined(separator: ", "), status: .tool)

        let encoder = JSONEncoder()
        let toolCallsJSON = (try? encoder.encode(stageCalls)).flatMap { String(data: $0, encoding: .utf8) }
        let assistant = ChatMessage(
            role: .assistant,
            content: plan.intro,
            toolCallsJSON: toolCallsJSON,
            conversation: conversation,
            runID: activeRunRecord?.id ?? activeRunID,
            runStatus: .running
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
            detail: stageCalls.map { $0.function.name }.joined(separator: ", "),
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
        for call in stageCalls {
            guard !Task.isCancelled, !stopRequested else { break }
            let request = ToolRequest(
                id: call.id,
                name: call.function.name,
                arguments: parseArguments(call.function.arguments)
            )

            if request.isMutating && !autoApproveWrites {
                pendingLocalPlanContinuation = PendingLocalPlanContinuation(
                    remainingCalls: remainingCalls,
                    completion: plan.completion
                )
                pendingTool = request
                runState = .waitingForApproval
                setActiveTool(request, title: "Approval needed")
                pushTrace("Approval needed", detail: request.argumentsJSON, status: .approval)

                let approvalRun = ToolRun(
                    name: request.name,
                    argumentsJSON: request.argumentsJSON,
                    status: .pendingApproval,
                    requiresApproval: true,
                    isMutating: true,
                    project: activeProject,
                    runID: activeRunRecord?.id ?? activeRunID,
                    runStatus: .awaitingApproval
                )
                pendingApprovalRun = approvalRun
                context.insert(approvalRun)
                ProjectEventRecorder.record(
                    project: activeProject,
                    kind: .toolApprovalRequested,
                    title: "Approval needed for \(request.name)",
                    detail: request.argumentsJSON,
                    severity: .warning,
                    sourceType: .toolRun,
                    sourceID: approvalRun.id,
                    context: context
                )
                try saveCompacted(context)
                isWorking = false
                return false
            }

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
                conversation: conversation,
                runID: activeRunRecord?.id ?? activeRunID,
                runStatus: .running
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
            let final = ChatMessage(
                role: .assistant,
                content: finalText,
                conversation: conversation,
                runID: activeRunRecord?.id ?? activeRunID,
                runStatus: .failed
            )
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

        return try finishLocalPlanCompletion(
            plan.completion,
            conversation: conversation,
            context: context,
            project: activeProject
        )
    }

    @discardableResult
    private func finishLocalPlanCompletion(
        _ completion: String,
        conversation: Conversation,
        context: ModelContext,
        project: Project?
    ) throws -> Bool {
        setActivity("Saving result", detail: "Local tool run completed.")
        let final = ChatMessage(
            role: .assistant,
            content: completion,
            conversation: conversation,
            runID: activeRunRecord?.id ?? activeRunID,
            runStatus: .running
        )
        conversation.appendMessage(final)
        context.insert(final)
        ProjectEventRecorder.record(
            project: project,
            kind: .responseSaved,
            title: "Local completion saved",
            detail: completion,
            severity: .success,
            sourceType: .message,
            sourceID: final.id,
            context: context
        )
        ProjectEventRecorder.record(
            project: project,
            kind: .runCompleted,
            title: "Local run complete",
            detail: completion,
            severity: .success,
            sourceType: .conversation,
            sourceID: conversation.id,
            context: context
        )
        ProjectEventRecorder.record(
            project: project,
            kind: .agentProofCreated,
            title: "Agent proof captured",
            detail: completion,
            severity: .success,
            sourceType: .conversation,
            sourceID: conversation.id,
            context: context
        )
        ProjectEventRecorder.recordMissionCheckpoint(
            project: project,
            trigger: "local-agent-proof",
            sourceType: .conversation,
            sourceID: conversation.id,
            context: context
        )
        try saveCompacted(context)
        pushTrace("Local run complete", detail: completion, status: .success)
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
        #if DEBUG || targetEnvironment(simulator)
        if let debugCompactedSaveOverride {
            try debugCompactedSaveOverride(context)
            return
        }
        #endif
        try context.save()
    }

    /// Send acceptance only inserts bounded records, so it must not rewrite or
    /// compact unrelated transcript rows before knowing the new turn is
    /// durable. Keeping this transaction narrow also makes manual rollback on
    /// failure exact and leaves any pre-existing context edits untouched.
    private func saveAcceptanceBoundary(_ context: ModelContext) throws {
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
        do {
            try context.save()
        } catch {
            // Do not let an unsaved ProjectEvent/ledger mutation leak into a
            // later unrelated save after reporting this failure.
            context.rollback()
            let message = friendlyError(error)
            presentToast("NovaForge could not save the latest run state: \(message)", tone: .error)
            pushTrace("Run state save failed", detail: message, status: .failed)
        }
    }

    private func appendVisibleErrorMessage(
        _ text: String,
        conversation: Conversation,
        context: ModelContext,
        project: Project?,
        sourceID: UUID?
    ) {
        let assistant = ChatMessage(
            role: .assistant,
            content: text,
            conversation: conversation,
            runID: activeRunRecord?.id ?? activeRunID,
            runStatus: .failed
        )
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
            context.rollback()
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

    private func beginRunIdentity(_ existingRunID: UUID? = nil) -> UUID {
        let runID = existingRunID ?? UUID()
        activeRunID = runID
        return runID
    }

    private func persistentOrigin(for origin: AgentRunOrigin) -> AgentRunRecordOrigin {
        switch origin {
        case .manual:
            return .user
        case .retry:
            return .retry
        case .continuation:
            return .continuation
        case .autoContinued:
            return .autoContinue
        }
    }

    @discardableResult
    private func persistActiveRunRecordState(
        runID expectedRunID: UUID,
        conversation: Conversation,
        context: ModelContext
    ) -> Bool {
        guard let record = activeRunRecord, record.id == expectedRunID else { return true }

        let status: AgentRunStatus
        let errorKind: AgentRunErrorKind?
        switch runState {
        case .idle:
            status = .interrupted
            errorKind = .interrupted
        case .running:
            status = .running
            errorKind = nil
        case .waitingForApproval:
            status = .awaitingApproval
            errorKind = nil
        case .completed:
            status = .completed
            errorKind = nil
        case .cancelled:
            // A user pressing Stop is a deliberate cancellation, while safety
            // limits and abandoned async work are interruptions that can be
            // continued. `wasInterrupted` remains a UI affordance for Stop, so
            // `stopRequested` is the more precise durable discriminator here.
            if stopRequested || !wasInterrupted {
                status = .cancelled
                errorKind = .cancelled
            } else {
                status = .interrupted
                errorKind = .interrupted
            }
        case .failed:
            status = .failed
            errorKind = .unknown
        }

        record.transition(
            to: status,
            errorKind: errorKind,
            errorMessage: status == .failed || status == .interrupted ? lastError ?? activityDetail : nil
        )

        let linkedMessages = conversation.messages
            .filter { message in
                if message.runID == record.id { return true }
                if message.id == record.requestMessageID { return true }
                return message.runID == nil &&
                    message.createdAt >= record.createdAt &&
                    !queuedFollowUpMessageIDs.contains(message.id)
            }
            .sorted(by: messageAscending)

        let runIDString = record.id.uuidString
        let linkedToolRunsDescriptor = FetchDescriptor<ToolRun>(
            predicate: #Predicate { $0.runIDString == runIDString }
        )
        let linkedToolRuns = (try? context.fetch(linkedToolRunsDescriptor)) ?? []

        stampRunTimeline(
            record: record,
            messages: linkedMessages,
            toolRuns: linkedToolRuns,
            status: status
        )

        if status.isTerminal {
            lastSettledRunID = record.id
            activeRunWorkspace = nil
        }

        do {
            try context.save()
            if status.isTerminal {
                activeRunRecord = nil
            }
            return true
        } catch {
            context.rollback()
            presentToast("NovaForge could not save the run receipt: \(friendlyError(error))", tone: .error)
            return false
        }
    }

    private func releaseRunWorkspaceIfSettled() {
        guard !isWorking, pendingTool == nil else { return }
        switch runState {
        case .idle, .completed, .cancelled, .failed:
            activeRunWorkspace = nil
        case .running, .waitingForApproval:
            break
        }
    }

    private func stampRunTimeline(
        record: AgentRunRecord,
        messages: [ChatMessage],
        toolRuns: [ToolRun],
        status: AgentRunStatus
    ) {
        // Use one stable chronological sequence across transcript messages and
        // tool receipts. That makes a run independently replayable instead of
        // leaving ToolRun.runSequence unset or assigning two conflicting clocks.
        var timeline: [(
            createdAt: Date,
            stableID: String,
            message: ChatMessage?,
            toolRun: ToolRun?
        )] = messages.map { message in
            (message.createdAt, "message-\(message.id.uuidString)", message, nil)
        }
        timeline.append(contentsOf: toolRuns.map { toolRun in
            (toolRun.createdAt, "tool-\(toolRun.id.uuidString)", nil, toolRun)
        })
        timeline.sort { lhs, rhs in
            if lhs.createdAt == rhs.createdAt {
                return lhs.stableID < rhs.stableID
            }
            return lhs.createdAt < rhs.createdAt
        }
        for (sequence, item) in timeline.enumerated() {
            if let message = item.message {
                message.runID = record.id
                message.runSequence = sequence
                message.runStatus = status
            }
            if let toolRun = item.toolRun {
                toolRun.runSequence = sequence
                toolRun.runStatus = status
            }
        }
        record.responseMessageID = messages
            .filter { $0.role == .assistant }
            .max(by: messageAscending)?
            .id
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
            projectName: runWorkspace.workspaceName,
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
        project: Project? = nil,
        settings: AgentSettings? = nil
    ) -> SendDisposition {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .rejected(.emptyPrompt) }
        queuedPromptCount = queuedPrompts.count
        guard trimmed.count <= maxQueuedPromptCharacters else {
            setActivity("Follow-up too long", detail: "Wait for the current run to finish, then send the large prompt.")
            pushTrace("Follow-up not queued", detail: "Prompt was over \(maxQueuedPromptCharacters) characters.", status: .failed)
            let reason = SendRejectionReason.followUpTooLong(limit: maxQueuedPromptCharacters)
            presentToast(reason.userMessage, tone: .info)
            return .rejected(reason)
        }
        guard queuedPrompts.count < maxQueuedPrompts else {
            setActivity("Follow-up queue full", detail: "\(maxQueuedPrompts) follow-ups are already waiting. Pause or let this run finish first.")
            pushTrace("Follow-up not queued", detail: "Queue limit reached: \(maxQueuedPrompts) waiting prompts.", status: .failed)
            let reason = SendRejectionReason.followUpQueueFull(limit: maxQueuedPrompts)
            presentToast(reason.userMessage, tone: .info)
            return .rejected(reason)
        }

        var visibleMessageID: UUID?
        var durableRun: AgentRunRecord?
        if let context {
            let previousUpdatedAt = conversation.updatedAt
            let previousMessageCount = conversation.messageCount
            let previousPreview = conversation.lastMessagePreview
            let previousHasUserMessages = conversation.hasUserMessages
            let userMessage = ChatMessage(role: .user, content: prompt, conversation: conversation)
            let queuedRun = AgentRunRecord(
                status: .queued,
                origin: .user,
                conversationID: conversation.id,
                projectID: (project ?? conversation.project)?.id,
                workspaceName: workspace.workspaceName,
                requestMessageID: userMessage.id,
                provider: settings?.provider,
                modelID: settings?.modelID
            )
            userMessage.runID = queuedRun.id
            userMessage.runStatus = .queued
            conversation.appendMessage(userMessage)
            context.insert(userMessage)
            context.insert(queuedRun)
            visibleMessageID = userMessage.id
            do {
                try saveAcceptanceBoundary(context)
            } catch {
                context.delete(queuedRun)
                rollbackUnsavedMessage(userMessage, from: conversation, context: context)
                conversation.updatedAt = previousUpdatedAt
                conversation.messageCount = previousMessageCount
                conversation.lastMessagePreview = previousPreview
                conversation.hasUserMessages = previousHasUserMessages
                let detail = friendlyError(error)
                let reason = SendRejectionReason.persistenceFailed(detail: detail)
                presentToast(reason.userMessage, tone: .error)
                pushTrace("Follow-up not saved", detail: detail, status: .failed)
                return .rejected(reason)
            }
            durableRun = queuedRun
            queuedFollowUpMessageIDs.insert(userMessage.id)
        }

        queuedPrompts.append(
            QueuedPrompt(
                text: prompt,
                conversation: conversation,
                visibleMessageID: visibleMessageID,
                durableRun: durableRun
            )
        )
        queuedPromptCount = queuedPrompts.count
        if let context {
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
        }
        setActivity("Prompt queued", detail: "\(queuedPromptCount) follow-up\(queuedPromptCount == 1 ? "" : "s") waiting.")
        pushTrace("Follow-up queued", detail: "Waiting for the current run to finish.", status: .queued)
        return .queued(position: queuedPromptCount)
    }

    private func drainQueueIfPossible(conversation: Conversation, settings: AgentSettings, context: ModelContext) {
        guard !stopRequested, pendingTool == nil, !isWorking else { return }
        guard !queuedPrompts.isEmpty else { return }
        if let runID = activeRunRecord?.id {
            guard persistActiveRunRecordState(
                runID: runID,
                conversation: lastRunConversation ?? conversation,
                context: context
            ) else {
                queuedPromptCount = queuedPrompts.count
                setActivity("Follow-up still queued", detail: "NovaForge could not settle the prior run receipt. Your queued message remains safe.")
                return
            }
        }
        let next = queuedPrompts[0]
        let disposition = startPrompt(
            next.text,
            conversation: next.conversation,
            settings: settings,
            context: context,
            project: next.conversation.project ?? conversation.project,
            clearsStaleQueuedFollowUps: false,
            origin: .manual,
            visiblePrompt: nil,
            existingVisibleUserMessageID: next.visibleMessageID,
            existingQueuedRun: next.durableRun
        )
        guard case .started = disposition else {
            // The persisted queued bubble remains both visible and queued. A
            // later retry can create its run receipt without reconstructing or
            // losing any user text.
            queuedPromptCount = queuedPrompts.count
            setActivity("Follow-up still queued", detail: "NovaForge could not save its run receipt yet. The message is safe in this chat.")
            return
        }
        queuedPrompts.removeFirst()
        queuedPromptCount = queuedPrompts.count
    }

    private func discardQueuedPrompts(
        context: ModelContext? = nil,
        terminalStatus: AgentRunStatus = .interrupted
    ) {
        guard !queuedPrompts.isEmpty || queuedPromptCount != 0 else { return }
        for prompt in queuedPrompts {
            if let messageID = prompt.visibleMessageID {
                queuedFollowUpMessageIDs.remove(messageID)
                if let message = prompt.conversation.messages.first(where: { $0.id == messageID }) {
                    message.runStatus = terminalStatus
                }
            }
            if let durableRun = prompt.durableRun {
                let wasQueued = durableRun.status == .queued
                let kind: AgentRunErrorKind = terminalStatus == .cancelled ? .cancelled : .interrupted
                let detail = terminalStatus == .cancelled
                    ? "The active run was cancelled before this accepted follow-up could start."
                    : "The active run ended before this accepted follow-up could start."
                durableRun.transition(to: terminalStatus, errorKind: kind, errorMessage: detail)
                // This receipt was accepted but never claimed by a provider
                // task, so do not invent a start timestamp while settling it.
                if wasQueued {
                    durableRun.startedAt = nil
                }
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
        // XCUI waits for a stable accessibility snapshot before querying a
        // rapidly changing hierarchy. Give the send-path UI fixture a calm,
        // observable cadence without changing real provider streaming or the
        // faster debug fixtures used elsewhere.
        let observableUITestStream = ProcessInfo.processInfo.arguments.contains("--ui-test-observable-stream")
        // Keep enough delay for the live bubble to be observable, while
        // bounding the fixture so the final durable message arrives under
        // slow CI simulator conditions.
        let batchLength = observableUITestStream ? 96 : 24
        let batchDelay = observableUITestStream ? Duration.seconds(1) : .milliseconds(160)
        var index = text.startIndex
        while index < text.endIndex {
            try Task.checkCancellation()
            let end = text.index(index, offsetBy: batchLength, limitedBy: text.endIndex) ?? text.endIndex
            onContentBatch(String(text[index..<end]))
            index = end
            if index < text.endIndex {
                try await Task.sleep(for: batchDelay)
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
            .filter { !queuedFollowUpMessageIDs.contains($0.id) && $0.runStatus != .queued }
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
            guard message.runStatus != .queued else { continue }
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
        let items = (try? runWorkspace.manifest(maxItems: provider == .local ? 120 : 500, maxDepth: provider == .local ? 3 : 5)) ?? []
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
        setActivity("Coordinating local model", detail: "Waiting for the shared on-device inference lane.")
        let inferenceLease = try await executionCoordinator.acquireLocalInference(
            runID: runID,
            ownerDescription: activeConversationTitle ?? runWorkspace.workspaceName
        )
        defer {
            Task { await executionCoordinator.release(inferenceLease) }
        }
        try requireActiveRun(runID)
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

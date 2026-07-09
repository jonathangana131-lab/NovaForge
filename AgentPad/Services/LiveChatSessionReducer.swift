import Foundation

enum LiveChatSessionReducer {
    static func presentation(forToolName name: String, arguments: [String: String] = [:], detail: String? = nil) -> (title: String, target: String?) {
        toolSummary(name: name, arguments: arguments, detail: detail)
    }

    static func humanizedVisibleText(_ text: String, fallback: String? = nil) -> String {
        humanActivity(text, fallback: fallback)
    }

    static func humanizedVisibleDetail(_ text: String?) -> String? {
        sanitizedDetail(text)
    }

    @MainActor
    static func reduce(runtime: AgentRuntime, providerDisplayName: String = "NovaForge", modelDisplayName: String? = nil) -> LiveChatSessionViewState {
        reduce(LiveChatSessionInput(runtime: runtime, providerDisplayName: providerDisplayName, modelDisplayName: modelDisplayName))
    }

    static func reduce(_ input: LiveChatSessionInput) -> LiveChatSessionViewState {
        let responseDocument = input.usesAIResponseStage ? input.liveResponseDocument : .empty
        let artifacts = mergedArtifactHandoffs(
            artifactHandoffs(from: input.currentArtifacts),
            responseDocument.artifacts
        )
        let progress = progressCards(from: input)
        let badges = badges(from: input)

        if let pendingTool = input.pendingTool {
            let summary = approvalSummary(for: pendingTool)
            return LiveChatSessionViewState(
                phase: .waitingForApproval(summary: summary),
                primaryLine: "Review this action",
                secondaryLine: summary,
                badges: badges + [LiveChatBadge(id: "approval", title: "Approval", symbolName: "hand.raised.fill", tone: .waiting)],
                actions: [action(.approve, title: "Approve", symbolName: "checkmark.circle.fill", primary: true), action(.reject, title: "Reject", symbolName: "xmark.circle")],
                progressCards: progress,
                artifactHandoffs: artifacts,
                shouldShowLiveRunCard: true,
                shouldShowInlineProgress: true,
                shouldReserveComposerQueue: true
            )
        }

        switch input.runState {
        case .idle:
            if input.isWorking {
                return workingState(input: input, badges: badges, progress: progress, artifacts: artifacts)
            }
            return .idle
        case .running:
            return workingState(input: input, badges: badges, progress: progress, artifacts: artifacts)
        case .waitingForApproval:
            return LiveChatSessionViewState(
                phase: .waitingForApproval(summary: "Waiting for your approval"),
                primaryLine: "Waiting for approval",
                secondaryLine: "Review the requested action before NovaForge continues.",
                badges: badges + [LiveChatBadge(id: "approval", title: "Approval", symbolName: "hand.raised.fill", tone: .waiting)],
                actions: [action(.approve, title: "Approve", symbolName: "checkmark.circle.fill", primary: true), action(.reject, title: "Reject", symbolName: "xmark.circle")],
                progressCards: progress,
                artifactHandoffs: artifacts,
                shouldShowLiveRunCard: true,
                shouldShowInlineProgress: true,
                shouldReserveComposerQueue: true
            )
        case .completed:
            let summary = completionSummary(input)
            var actions = [action(.continueFromResult, title: "Continue", symbolName: "arrow.turn.down.right", primary: true)]
            if !artifacts.isEmpty {
                actions.insert(action(.openArtifact, title: "Open artifact", symbolName: "shippingbox.fill", primary: true), at: 0)
            } else if input.traceEvents.contains(where: { $0.status == .success }) {
                actions.append(action(.openProof, title: "Open proof", symbolName: "checkmark.seal.fill"))
            }
            return LiveChatSessionViewState(
                phase: .completed(summary: summary),
                primaryLine: "Ready to review",
                secondaryLine: summary,
                badges: badges + [LiveChatBadge(id: "complete", title: "Done", symbolName: "checkmark.circle.fill", tone: .success)],
                actions: actions,
                progressCards: progress,
                artifactHandoffs: artifacts,
                shouldShowLiveRunCard: !progress.isEmpty || !artifacts.isEmpty,
                shouldShowInlineProgress: !progress.isEmpty,
                shouldReserveComposerQueue: false
            )
        case .cancelled:
            return LiveChatSessionViewState(
                phase: .cancelled,
                primaryLine: "Run stopped",
                secondaryLine: "You can continue from the last visible result.",
                badges: [LiveChatBadge(id: "stopped", title: "Stopped", symbolName: "stop.circle", tone: .neutral)],
                actions: [action(.continueFromResult, title: "Continue", symbolName: "arrow.turn.down.right", primary: true)],
                progressCards: progress,
                artifactHandoffs: artifacts,
                shouldShowLiveRunCard: true,
                shouldShowInlineProgress: !progress.isEmpty,
                shouldReserveComposerQueue: false
            )
        case .failed(let message):
            let recovery = LiveChatRecoveryAction.standardFailure
            return LiveChatSessionViewState(
                phase: .failed(summary: humanFailure(message), recovery: recovery),
                primaryLine: "Needs recovery",
                secondaryLine: humanFailure(message),
                badges: [LiveChatBadge(id: "failed", title: "Failed", symbolName: "exclamationmark.triangle.fill", tone: .danger)],
                actions: [
                    action(.retry, title: "Retry", symbolName: "arrow.clockwise", primary: true),
                    action(.switchModel, title: "Switch model", symbolName: "cpu"),
                    action(.copyDetails, title: "Copy details", symbolName: "doc.on.doc")
                ],
                progressCards: progress,
                artifactHandoffs: artifacts,
                shouldShowLiveRunCard: true,
                shouldShowInlineProgress: !progress.isEmpty,
                shouldReserveComposerQueue: false
            )
        }
    }

    private static func workingState(
        input: LiveChatSessionInput,
        badges: [LiveChatBadge],
        progress: [LiveChatProgressCard],
        artifacts: [LiveChatArtifactHandoff]
    ) -> LiveChatSessionViewState {
        let baseActions = runningActions(input)

        if input.usesAIResponseStage, !input.liveResponseDocument.isEmpty {
            let summary = semanticStreamingSummary(input.liveResponseDocument)
            return LiveChatSessionViewState(
                phase: .streaming(summary: summary),
                primaryLine: summary,
                secondaryLine: semanticStreamingDetail(input.liveResponseDocument),
                badges: badges + [LiveChatBadge(id: "ai-response-stage", title: "Live", symbolName: "text.bubble", tone: .active)],
                actions: baseActions,
                progressCards: progress,
                artifactHandoffs: artifacts,
                liveResponseDocument: input.liveResponseDocument,
                usesAIResponseStage: true,
                shouldShowLiveRunCard: true,
                shouldShowInlineProgress: false,
                shouldReserveComposerQueue: true
            )
        }

        if let tool = activeToolSummary(input) {
            return LiveChatSessionViewState(
                phase: .usingTool(name: tool.title, target: tool.target),
                primaryLine: tool.title,
                secondaryLine: tool.target,
                badges: badges + [LiveChatBadge(id: "tool", title: "Tool", symbolName: "wrench.and.screwdriver.fill", tone: .active)],
                actions: baseActions,
                progressCards: progress,
                artifactHandoffs: artifacts,
                shouldShowLiveRunCard: true,
                shouldShowInlineProgress: true,
                shouldReserveComposerQueue: true
            )
        }

        if !input.liveStream.isEmpty {
            let summary = streamingSummary(input)
            return LiveChatSessionViewState(
                phase: .streaming(summary: summary),
                primaryLine: summary,
                secondaryLine: streamingDetail(input),
                badges: badges + [LiveChatBadge(id: "live", title: "Live", symbolName: "waveform", tone: .active)],
                actions: baseActions,
                progressCards: progress,
                artifactHandoffs: artifacts,
                shouldShowLiveRunCard: true,
                shouldShowInlineProgress: !progress.isEmpty,
                shouldReserveComposerQueue: true
            )
        }

        if isConnecting(input) {
            let provider = input.modelDisplayName ?? input.providerDisplayName
            return LiveChatSessionViewState(
                phase: .connecting(provider: provider),
                primaryLine: "Waiting for model",
                secondaryLine: "Asking \(provider).",
                badges: badges + [LiveChatBadge(id: "model", title: input.providerDisplayName, symbolName: "cpu", tone: .active)],
                actions: baseActions,
                progressCards: progress,
                artifactHandoffs: artifacts,
                shouldShowLiveRunCard: true,
                shouldShowInlineProgress: true,
                shouldReserveComposerQueue: true
            )
        }

        let summary = humanActivity(input.activityTitle, fallback: "Thinking through your request")
        return LiveChatSessionViewState(
            phase: .thinking(summary: summary),
            primaryLine: summary,
            secondaryLine: humanActivity(input.activityDetail ?? "", fallback: nil),
            badges: badges + [LiveChatBadge(id: "thinking", title: "Working", symbolName: "sparkles", tone: .active)],
            actions: baseActions,
            progressCards: progress,
            artifactHandoffs: artifacts,
            shouldShowLiveRunCard: true,
            shouldShowInlineProgress: !progress.isEmpty,
            shouldReserveComposerQueue: true
        )
    }

    private static func runningActions(_ input: LiveChatSessionInput) -> [LiveChatAction] {
        var actions = [
            action(.addInstruction, title: "Add instruction", symbolName: "plus.bubble", primary: input.queuedPromptCount == 0),
            action(.stop, title: "Stop", symbolName: "stop.fill")
        ]
        if input.queuedPromptCount > 0 {
            actions.insert(action(.queueFollowUp, title: "Queue follow-up", symbolName: "text.badge.plus", primary: true), at: 0)
        }
        return actions
    }

    private static func badges(from input: LiveChatSessionInput) -> [LiveChatBadge] {
        var result: [LiveChatBadge] = []
        if input.queuedPromptCount > 0 {
            result.append(LiveChatBadge(id: "queue", title: "\(input.queuedPromptCount) queued", symbolName: "text.line.first.and.arrowtriangle.forward", tone: .waiting))
        }
        return result
    }

    private static func progressCards(from input: LiveChatSessionInput) -> [LiveChatProgressCard] {
        let traceCards = input.traceEvents.suffix(5).map { event in
            LiveChatProgressCard(
                id: event.id.uuidString,
                title: humanTraceTitle(event.title, status: event.status),
                detail: sanitizedDetail(event.detail),
                symbolName: symbolName(for: event.status),
                state: cardState(for: event.status)
            )
        }
        if !traceCards.isEmpty { return traceCards }

        return input.plannedProgressSteps.prefix(5).map { step in
            LiveChatProgressCard(
                id: step.id,
                title: humanActivity(step.title, fallback: step.title),
                detail: sanitizedDetail(step.detail),
                symbolName: step.symbolName,
                state: cardState(for: step.state)
            )
        }
    }

    private static func artifactHandoffs(from artifacts: [WorkspaceArtifact]) -> [LiveChatArtifactHandoff] {
        artifacts.prefix(3).map { artifact in
            LiveChatArtifactHandoff(
                id: artifact.id,
                title: artifact.title,
                subtitle: "Ready in Workspace",
                path: artifact.path,
                typeName: artifact.artifactType.displayName,
                primaryActionTitle: artifact.isReadablePreviewArtifact ? "Preview" : "Open"
            )
        }
    }

    private static func mergedArtifactHandoffs(_ primary: [LiveChatArtifactHandoff], _ semantic: [LiveChatArtifactHandoff]) -> [LiveChatArtifactHandoff] {
        var seen = Set<String>()
        var merged: [LiveChatArtifactHandoff] = []
        for handoff in primary + semantic {
            guard seen.insert(handoff.id).inserted else { continue }
            merged.append(handoff)
            if merged.count == 3 { break }
        }
        return merged
    }

    private static func semanticStreamingSummary(_ document: AIStreamDocument) -> String {
        switch document.status {
        case .connecting:
            return "Waiting for model"
        case .usingTool(let title):
            return title
        case .waitingApproval:
            return "Waiting for approval"
        case .finalizing:
            return "Finishing response…"
        case .complete:
            return "Ready to review"
        case .failed:
            return "Needs recovery"
        case .idle, .composing:
            return document.activeFragment.isEmpty ? "Finishing response…" : "Writing answer…"
        }
    }

    private static func semanticStreamingDetail(_ document: AIStreamDocument) -> String? {
        switch document.status {
        case .connecting(let label):
            return "Asking \(label)."
        case .usingTool:
            return "Keeping the answer in place while work continues."
        case .waitingApproval(let summary):
            return summary
        case .failed(let summary):
            return summary
        case .complete:
            return document.artifacts.isEmpty ? "Response is ready." : "Artifact ready in Workspace."
        case .finalizing:
            return "Finishing the last visible phrase."
        case .idle, .composing:
            return nil
        }
    }

    private static func activeToolSummary(_ input: LiveChatSessionInput) -> (title: String, target: String?)? {
        if let name = input.activeToolName, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return toolSummary(name: name, arguments: [:], detail: input.activeToolDetail)
        }
        if let event = input.traceEvents.reversed().first(where: { [.tool, .executing].contains($0.status) }) {
            return (humanTraceTitle(event.title, status: event.status), sanitizedDetail(event.detail))
        }
        return nil
    }

    private static func approvalSummary(for request: ToolRequest) -> String {
        let summary = toolSummary(name: request.name, arguments: request.arguments, detail: nil)
        if let target = summary.target, !target.isEmpty {
            return "\(summary.title): \(target)"
        }
        return summary.title
    }

    private static func toolSummary(name: String, arguments: [String: String], detail: String?) -> (title: String, target: String?) {
        let target = arguments["path"] ?? arguments["file"] ?? arguments["to"] ?? arguments["from"] ?? sanitizedDetail(detail ?? "")
        let loweredName = name.lowercased()
        if loweredName.contains("word tree") || loweredName.contains("live feed") || loweredName.contains("response renderer") {
            return ("Writing answer…", target)
        }
        switch name {
        case "read_file", "read_file_range", "tail_file", "file_info":
            return ("Inspecting file", target)
        case "list_directory", "list_tree", "workspace_summary", "search_files", "search":
            return ("Searching workspace", target)
        case "write_file", "append_file", "make_directory":
            return ("Writing file", target)
        case "replace_text", "move_path", "copy_path":
            return ("Editing file", target)
        case "delete_path":
            return ("Deleting file", target)
        case "run_command":
            let command = arguments["command"] ?? detail ?? ""
            if command.localizedCaseInsensitiveContains("xcodebuild") {
                return ("Running Xcode proof", nil)
            }
            if command.localizedCaseInsensitiveContains("screenshot") || command.localizedCaseInsensitiveContains("simctl io") {
                return ("Capturing proof", nil)
            }
            return ("Running command", sanitizedDetail(command))
        default:
            return (humanActivity(name.replacingOccurrences(of: "_", with: " "), fallback: "Using tool"), target)
        }
    }

    private static func streamingSummary(_ input: LiveChatSessionInput) -> String {
        if input.liveStream.revealBacklog > 0 { return "Writing answer…" }
        if input.liveStream.isShowingTail { return "Still streaming…" }
        return "Finishing response…"
    }

    private static func streamingDetail(_ input: LiveChatSessionInput) -> String? {
        let detail = humanActivity(input.activityDetail ?? input.activityTitle, fallback: "")
        return detail.isEmpty ? "Keeping the live response readable." : detail
    }

    private static func isConnecting(_ input: LiveChatSessionInput) -> Bool {
        let joined = "\(input.activityTitle) \(input.activityDetail ?? "")"
        return joined.localizedCaseInsensitiveContains("model") ||
            joined.localizedCaseInsensitiveContains("provider") ||
            joined.localizedCaseInsensitiveContains("openai") ||
            joined.localizedCaseInsensitiveContains("syncing workspace") ||
            joined.localizedCaseInsensitiveContains("loading local")
    }

    private static func completionSummary(_ input: LiveChatSessionInput) -> String {
        if let artifact = input.currentArtifacts.first {
            return "Created \(artifact.title)."
        }
        if let success = input.traceEvents.reversed().first(where: { $0.status == .success }) {
            return humanActivity(success.detail.isEmpty ? success.title : success.detail, fallback: "Run completed.")
        }
        return "Run completed."
    }

    private static func humanFailure(_ message: String) -> String {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "The run stopped before finishing." }
        return trimmed
    }

    private static func humanTraceTitle(_ title: String, status: AgentTraceStatus) -> String {
        let lower = title.lowercased()
        if lower.contains("read") || lower.contains("inspect") { return "Inspecting workspace" }
        if lower.contains("write") || lower.contains("edit") || lower.contains("patch") { return "Editing files" }
        if lower.contains("command") || lower.contains("check") || lower.contains("test") { return "Running checks" }
        if lower.contains("proof") || lower.contains("screenshot") { return "Capturing proof" }
        if status == .success { return "Proof passed" }
        if status == .failed { return "Needs recovery" }
        return humanActivity(title, fallback: "Working")
    }

    private static func humanActivity(_ text: String, fallback: String?) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return fallback ?? "" }
        let lower = trimmed.lowercased()
        if lower.contains("word tree") { return "Writing answer…" }
        if lower.contains("word-tree") { return "Writing answer…" }
        if lower.contains("normalizing chunk") { return "Organizing the response" }
        if lower.contains("semantic reveal") { return "Keeping the live response readable." }
        if lower.contains("ragged chunks") { return "Smoothing the live response." }
        if lower.contains("streaming stress test") { return "Writing answer…" }
        if lower == "ready" { return fallback ?? "Ready" }
        if lower.contains("calling openai") { return "Waiting for model" }
        return trimmed.prefix(1).uppercased() + trimmed.dropFirst()
    }

    private static func sanitizedDetail(_ text: String?) -> String? {
        guard let text else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.localizedCaseInsensitiveContains("normalizing chunk") { return "Organizing the response" }
        if trimmed.localizedCaseInsensitiveContains("word tree") { return "Writing answer" }
        if trimmed.localizedCaseInsensitiveContains("word-tree") { return "Writing answer" }
        if trimmed.localizedCaseInsensitiveContains("semantic reveal") { return "Keeping the live response readable." }
        if trimmed.localizedCaseInsensitiveContains("ragged chunks") { return "Smoothing the live response." }
        if trimmed.first == "{" || trimmed.first == "[" { return "Details saved in History." }
        return trimmed
    }

    private static func symbolName(for status: AgentTraceStatus) -> String {
        switch status {
        case .queued: "clock"
        case .thinking, .planning: "sparkles"
        case .tool, .executing: "wrench.and.screwdriver.fill"
        case .approval, .paused: "hand.raised.fill"
        case .success: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        }
    }

    private static func cardState(for status: AgentTraceStatus) -> LiveChatProgressCard.State {
        switch status {
        case .queued: .pending
        case .thinking, .planning, .tool, .executing: .active
        case .approval, .paused: .waiting
        case .success: .done
        case .failed: .failed
        }
    }

    private static func cardState(for state: WorkspaceProgressStep.State) -> LiveChatProgressCard.State {
        switch state {
        case .pending: .pending
        case .current: .active
        case .done: .done
        case .blocked: .failed
        }
    }

    private static func action(_ kind: LiveChatActionKind, title: String, symbolName: String, primary: Bool = false) -> LiveChatAction {
        LiveChatAction(kind: kind, title: title, symbolName: symbolName, isPrimary: primary)
    }
}

@MainActor
extension LiveChatSessionInput {
    init(runtime: AgentRuntime, providerDisplayName: String = "NovaForge", modelDisplayName: String? = nil) {
        let frame = runtime.liveStream.displayFrame
        self.init(
            runState: runtime.runState,
            isWorking: runtime.isWorking,
            activityTitle: runtime.activityTitle,
            activityDetail: runtime.activityDetail,
            activeToolName: runtime.activeToolName,
            activeToolDetail: runtime.activeToolDetail,
            pendingTool: runtime.pendingTool,
            traceEvents: runtime.traceEvents,
            plannedProgressSteps: runtime.plannedProgressSteps,
            currentArtifacts: runtime.currentArtifacts,
            liveStream: LiveChatStreamSnapshot(
                displayText: frame.displayText,
                characterCount: frame.characterCount,
                revealBacklog: frame.backlogCharacters,
                isShowingTail: frame.isShowingTail
            ),
            liveResponseDocument: runtime.liveStream.responseDocument,
            usesAIResponseStage: runtime.liveStream.shouldUseResponseStage,
            queuedPromptCount: runtime.queuedPromptCount,
            providerDisplayName: providerDisplayName,
            modelDisplayName: modelDisplayName
        )
    }
}

import SwiftUI

#if DEBUG
/// Compact fallback for V1 provider messages that have no canonical journal
/// projection. It is compiled only for DEBUG and `MessageBubble` additionally
/// requires `--legacy-v1-tool-ui`, so it cannot become a Release transcript.
struct AssistantToolCallBubble: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let content: String
    let blocks: [MarkdownBlock]
    let toolCalls: [ToolCallSnapshot]
    var workspace: SandboxWorkspace
    let openArtifact: (WorkspaceArtifact) -> Void
    @State private var detailsExpanded = false

    private let expandedDetailLimit = 12

    private var visibleToolCalls: ArraySlice<ToolCallSnapshot> {
        guard detailsExpanded else { return toolCalls.prefix(0) }
        return toolCalls.prefix(expandedDetailLimit)
    }

    private var hiddenToolCallCount: Int {
        max(toolCalls.count - visibleToolCalls.count, 0)
    }

    private var batchPresentation: LegacyToolActivityBatchPresentation {
        LegacyToolActivityBatchPresentation(
            totalCount: toolCalls.count,
            completedCount: successfulToolCallCount,
            failedCount: failedToolCallCount,
            pendingApprovalCount: pendingApprovalToolCallCount,
            primaryTarget: primaryTargetName
        )
    }

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "sparkles")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(AgentPalette.primaryAccent.opacity(0.72))
                .frame(width: 18, height: 22, alignment: .top)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 10) {
                if !content.isEmpty {
                    if blocks.isEmpty {
                        AssistantTextBlockView(content: content)
                    } else {
                        ForEach(blocks) { block in
                            if block.isCode {
                                CodeBlockView(block: block, workspace: workspace)
                            } else {
                                AssistantTextBlockView(content: block.content)
                            }
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 7) {
                    ToolActivityCompletionLine(
                        summary: batchPresentation.summary,
                        symbol: batchPresentation.symbol,
                        tint: batchTint,
                        artifact: allToolCallsResolved ? primaryArtifact : nil,
                        detailsExpanded: detailsExpanded,
                        toggleDetails: toggleDetails,
                        openArtifact: openArtifact
                    )

                    if detailsExpanded {
                        detailRows
                            .transition(.opacity)

                        if hiddenToolCallCount > 0 {
                            Text("\(hiddenToolCallCount) more action\(hiddenToolCallCount == 1 ? "" : "s") in History")
                                .font(NovaType.caption)
                                .foregroundStyle(AgentPalette.tertiaryText)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .frame(minHeight: AgentDesign.minimumTouchTarget)
                                .accessibilityIdentifier("toolActivityCappedCount")
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .agentRowSurface(radius: 15, tint: batchTint.opacity(0.07))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 18)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chatAssistantToolResponse")
    }

    private var detailRows: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(visibleToolCalls, id: \.id) { call in
                ToolActivityRow(
                    call: call,
                    showResultDetailByDefault: detailsExpanded && call.isError,
                    openArtifact: openArtifact
                )
            }
        }
    }

    private var failedToolCallCount: Int {
        toolCalls.filter(\.isError).count
    }

    private var successfulToolCallCount: Int {
        toolCalls.filter { $0.isComplete && !$0.isError }.count
    }

    private var pendingApprovalToolCallCount: Int {
        toolCalls.filter {
            !$0.isComplete && LegacyToolActivityPolicy.requiresApproval($0.name)
        }.count
    }

    private var allToolCallsResolved: Bool {
        !toolCalls.isEmpty && toolCalls.allSatisfy(\.isComplete)
    }

    private var primaryArtifact: WorkspaceArtifact? {
        toolCalls.compactMap(\.artifact).first
    }

    // Legacy inspection never reconstructs argument targets. Those values can
    // contain commands, paths, or provider payloads; History owns diagnostics.
    private var primaryTargetName: String? { nil }

    private var batchTint: Color {
        switch batchPresentation.phase {
        case .running: AgentPalette.cyan
        case .awaitingApproval: AgentPalette.warning
        case .succeeded: AgentPalette.green
        case .failed: AgentPalette.rose
        }
    }

    private func toggleDetails() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        withAnimation(
            NovaMotion.enabled(reduceMotion: reduceMotion)
                ? .smooth(duration: 0.18)
                : nil
        ) {
            detailsExpanded.toggle()
        }
    }
}

private struct ToolActivityCompletionLine: View {
    let summary: String
    let symbol: String
    let tint: Color
    let artifact: WorkspaceArtifact?
    let detailsExpanded: Bool
    let toggleDetails: () -> Void
    let openArtifact: (WorkspaceArtifact) -> Void

    var body: some View {
        GlassGroup(spacing: 6) {
            HStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(tint.opacity(0.12))
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(tint.opacity(0.24), lineWidth: 0.5)
                    Image(systemName: symbol)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(tint)
                }
                .frame(width: 22, height: 22)
                .accessibilityHidden(true)

                Text(summary)
                    .font(.system(size: 11.5, weight: .semibold, design: AgentPalette.interfaceFontDesign))
                    .foregroundStyle(AgentPalette.secondaryText)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .layoutPriority(1)
                    .accessibilityIdentifier("toolActivitySummary")

                if let artifact {
                    Button {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        openArtifact(artifact)
                    } label: {
                        Label("Open", systemImage: artifact.isWebPage || artifact.isSwiftGameArtifact ? artifact.handoffSymbol : artifact.symbol)
                            .labelStyle(.iconOnly)
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(AgentPalette.cyan)
                            .frame(width: AgentDesign.minimumTouchTarget)
                            .frame(minHeight: AgentDesign.minimumTouchTarget)
                            .contentShape(Circle())
                    }
                    .agentInteractiveGlassButtonStyle(
                        radius: AgentDesign.minimumTouchTarget / 2,
                        tint: AgentPalette.cyan
                    )
                    .accessibilityLabel("Open \(artifact.title)")
                    .accessibilityIdentifier("toolArtifactOpenButton")
                }

                Button(action: toggleDetails) {
                    Label(
                        detailsExpanded ? "Hide action details" : "Show action details",
                        systemImage: detailsExpanded ? "chevron.up" : "chevron.down"
                    )
                    .labelStyle(.iconOnly)
                        .font(.system(size: 10, weight: .black))
                        .foregroundStyle(tint)
                        .frame(width: AgentDesign.minimumTouchTarget)
                        .frame(minHeight: AgentDesign.minimumTouchTarget)
                        .contentShape(Circle())
                }
                .agentInteractiveGlassButtonStyle(
                    radius: AgentDesign.minimumTouchTarget / 2,
                    tint: tint,
                    selected: detailsExpanded
                )
                .accessibilityLabel(detailsExpanded ? "Hide action details" : "Show action details")
                .accessibilityIdentifier("toolBatchToggle")
            }
        }
        .padding(.horizontal, 2)
        .frame(minHeight: AgentDesign.minimumTouchTarget)
        .accessibilityElement(children: .contain)
    }
}

private struct ToolActivityRow: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let call: ToolCallSnapshot
    let showResultDetailByDefault: Bool
    let openArtifact: (WorkspaceArtifact) -> Void
    @State private var detailsExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                statusIcon
                    .frame(width: 22, height: 22)

                if call.isComplete || call.isError {
                    Text(activityText)
                        .font(.system(size: 12, weight: .semibold, design: AgentPalette.interfaceFontDesign))
                        .foregroundStyle(call.isError ? AgentPalette.rose : AgentPalette.secondaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else {
                    // Running rows shimmer softly — a live signal without a
                    // layout-shifting progress element.
                    LiveShimmerText(
                        text: activityText,
                        baseColor: AgentPalette.secondaryText,
                        highlightColor: AgentPalette.ink,
                        font: .system(size: 12, weight: .semibold, design: AgentPalette.interfaceFontDesign)
                    )
                    .lineLimit(1)
                }

                Spacer(minLength: 4)

                if let statusLabelText {
                    Text(statusLabelText)
                        .font(.system(size: 8.5, weight: .black, design: AgentPalette.interfaceFontDesign))
                        .foregroundStyle(statusTint)
                        .lineLimit(1)
                        .padding(.horizontal, 6)
                        .frame(height: 16)
                        .background(statusTint.opacity(0.12), in: Capsule())
                        .overlay(Capsule().strokeBorder(statusTint.opacity(0.22), lineWidth: 0.5))
                }

                if let artifact = call.artifact {
                    Button {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        openArtifact(artifact)
                    } label: {
                        Image(systemName: artifact.isWebPage || artifact.isSwiftGameArtifact ? artifact.handoffSymbol : artifact.symbol)
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(AgentPalette.cyan)
                            .frame(width: AgentDesign.minimumTouchTarget, height: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Open \(artifact.title)")
                    .accessibilityIdentifier("toolArtifactOpenButton")
                }

                if hasHiddenDetail && !showResultDetailByDefault {
                    Button {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        withAnimation(
                            NovaMotion.enabled(reduceMotion: reduceMotion)
                                ? .smooth(duration: 0.18)
                                : nil
                        ) {
                            detailsExpanded.toggle()
                        }
                    } label: {
                        Image(systemName: detailsExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 10, weight: .black))
                            .foregroundStyle(statusTint)
                            .frame(width: AgentDesign.minimumTouchTarget, height: AgentDesign.minimumTouchTarget)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(detailsExpanded ? "Hide tool result" : "Show tool result")
                    .accessibilityIdentifier("toolResultToggle")
                }
            }
            .frame(minHeight: 26)

            if resultDetailVisible, hasHiddenDetail {
                Text(call.isError ? "Open History for diagnostics." : "Receipt saved in History.")
                    .font(.system(size: 11, weight: .medium, design: AgentPalette.interfaceFontDesign))
                    .foregroundStyle(call.isError ? AgentPalette.rose : AgentPalette.secondaryText)
                    .lineLimit(4)
                    .padding(.leading, 23)
                    .padding(.trailing, 6)
                    .padding(.vertical, 3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .transition(.opacity)
                    .accessibilityIdentifier("toolResultDetail")
            }
        }
        .padding(.horizontal, 2)
        .padding(.vertical, 1)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("toolActivityRow")
    }

    @ViewBuilder
    private var statusIcon: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(statusTint.opacity(call.isError ? 0.16 : 0.11))
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(statusTint.opacity(0.24), lineWidth: 0.5)

            if call.isComplete || call.isError {
                Image(systemName: statusIconName)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(statusTint)
            } else if isWaitingForApprovalCandidate {
                Image(systemName: "checkmark.shield.fill")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(statusTint)
            } else {
                ProgressView()
                    .tint(statusTint)
                    .scaleEffect(0.58)
            }
        }
    }

    private var displayName: String {
        plainToolName(call.name)
    }

    private var activityText: String {
        if call.isError {
            switch call.name {
            case "read_file", "read_file_range", "tail_file":
                return targetName.map { "Could not read \($0)" } ?? "Read failed"
            case "run_command":
                return targetName.map { "Command failed: \($0)" } ?? "Command failed"
            case "validate_json", "validate_html_file":
                return targetName.map { "Check failed for \($0)" } ?? "Check failed"
            default:
                return targetName.map { "\(displayName) failed: \($0)" } ?? "\(displayName) failed"
            }
        }
        if let artifact = call.artifact { return "Saved \(artifact.title)" }
        if isWaitingForApprovalCandidate {
            switch call.name {
            case "write_file", "append_file", "replace_text":
                return targetName.map { "Waiting approval to edit \($0)" } ?? "Waiting for approval..."
            case "run_command":
                return "Waiting approval to run command"
            case "delete_path":
                return targetName.map { "Waiting approval to delete \($0)" } ?? "Waiting for approval..."
            case "move_path":
                return targetName.map { "Waiting approval to move \($0)" } ?? "Waiting for approval..."
            default:
                return "Waiting for approval..."
            }
        }
        switch call.name {
        case "read_file", "read_file_range", "tail_file":
            return call.isComplete
                ? (targetName.map { "Read \($0)" } ?? "Read files")
                : (targetName.map { "Reading \($0)..." } ?? "Reading files...")
        case "list_directory", "list_tree", "workspace_summary", "file_info":
            return call.isComplete
                ? (targetName.map { "Read \($0)" } ?? "Read project")
                : (targetName.map { "Reading \($0)..." } ?? "Reading project...")
        case "write_file", "append_file", "replace_text":
            if call.isComplete {
                return targetName.map { "Saved \($0)" } ?? "Saved files"
            }
            return targetName.map { "Editing \($0)..." } ?? "Editing files..."
        case "search_text":
            return call.isComplete ? "Searched files" : "Searching..."
        case "diff_files":
            return call.isComplete ? "Compared files" : "Comparing files..."
        case "validate_json":
            return call.isComplete ? "Checked JSON" : "Checking JSON..."
        case "validate_html_file":
            return call.isComplete
                ? (targetName.map { "Checked \($0)" } ?? "Checked HTML")
                : (targetName.map { "Checking \($0)..." } ?? "Checking HTML...")
        case "run_command":
            return call.isComplete ? "Ran command" : "Running command..."
        case "make_directory":
            return targetName.map { "Created \($0)" } ?? (call.isComplete ? "Created folder" : "Creating folder...")
        case "delete_path":
            return targetName.map { "Deleted \($0)" } ?? (call.isComplete ? "Deleted path" : "Deleting path...")
        case "move_path":
            return targetName.map { "Moved \($0)" } ?? (call.isComplete ? "Moved path" : "Moving path...")
        case "copy_path":
            return targetName.map { "Copied \($0)" } ?? (call.isComplete ? "Copied path" : "Copying path...")
        default:
            return call.isComplete ? "\(displayName) completed" : "\(displayName)..."
        }
    }

    private var hasHiddenDetail: Bool { call.isComplete }

    private var resultDetailVisible: Bool {
        showResultDetailByDefault || detailsExpanded
    }

    private var isWaitingForApprovalCandidate: Bool {
        !call.isComplete && LegacyToolActivityPolicy.requiresApproval(call.name)
    }

    private var targetName: String? { nil }

    private var toolIconName: String {
        switch call.name {
        case "read_file", "read_file_range", "tail_file", "list_directory", "list_tree", "workspace_summary", "file_info", "search_text", "extract_outline": "magnifyingglass"
        case "write_file", "append_file", "replace_text": "square.and.pencil"
        case "diff_files": "doc.on.doc.fill"
        case "validate_json", "validate_html_file": "checkmark.seal.fill"
        case "run_command": "terminal.fill"
        case "delete_path": "trash.fill"
        case "move_path", "copy_path": "arrow.triangle.branch"
        default: "wrench.and.screwdriver.fill"
        }
    }

    private var statusIconName: String {
        if call.isError { return "exclamationmark.triangle.fill" }
        if call.isComplete { return "checkmark.circle.fill" }
        return toolIconName
    }

    private var statusText: String {
        if call.isError { return "Failed" }
        if call.isComplete { return "Completed" }
        if isWaitingForApprovalCandidate { return "Approval" }
        return "Preparing"
    }

    private var statusTint: Color {
        if call.isError { return AgentPalette.rose }
        if call.isComplete { return AgentPalette.green }
        return AgentPalette.cyan
    }

    private var statusLabelText: String? {
        if call.isError { return "Review" }
        if isWaitingForApprovalCandidate { return "Approval" }
        if !call.isComplete { return "Running" }
        return nil
    }
}
#endif

struct LiveResponseView: View {
    let isWorking: Bool
    let isHandoffActive: Bool
    let stream: LiveStreamBuffer

    var body: some View {
        let _ = AgentPerformance.bodyEvaluation("Chat Live Response Body")
        Group {
            if isWorking || isHandoffActive {
                AIResponseStageView(
                    stream: stream,
                    isWorking: isWorking,
                    isHandoffActive: isHandoffActive
                )
            }
        }
    }
}

/// Retained as a shared status-label type, now intentionally static. Continuous
/// shimmer masks caused extra offscreen rendering while the transcript was
/// already updating at display cadence.
struct LiveShimmerText: View {
    let text: String
    let baseColor: Color
    let highlightColor: Color
    let font: Font

    var body: some View {
        Text(text)
            .font(font)
            .foregroundStyle(baseColor)
    }
}

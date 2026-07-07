import SwiftUI

struct AssistantToolCallBubble: View {
    let content: String
    let toolCalls: [ToolCallSnapshot]
    let openArtifact: (WorkspaceArtifact) -> Void
    @State private var detailsExpanded = false

    private let collapsedLimit = 4

    private var visibleToolCalls: ArraySlice<ToolCallSnapshot> {
        guard !detailsExpanded, !allToolCallsResolved, toolCalls.count > collapsedLimit else {
            return toolCalls[...]
        }
        return toolCalls.prefix(collapsedLimit)
    }

    private var hiddenToolCallCount: Int {
        max(toolCalls.count - collapsedLimit, 0)
    }

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 7) {
                if !content.isEmpty {
                    Text(content)
                        .font(.system(size: 16, weight: .regular, design: AgentPalette.interfaceFontDesign))
                        .foregroundStyle(AgentPalette.ink)
                        .lineSpacing(5)
                        .padding(.horizontal, 2)
                }

                if allToolCallsResolved {
                    ToolActivityCompletionLine(
                        summary: resolvedSummaryText,
                        symbol: resolvedSummarySymbol,
                        tint: resolvedSummaryTint,
                        artifact: primaryArtifact,
                        detailsExpanded: detailsExpanded,
                        toggleDetails: toggleDetails,
                        openArtifact: openArtifact
                    )

                    if detailsExpanded {
                        detailRows
                            .transition(.opacity)
                    }
                } else {
                    detailRows

                    if hiddenToolCallCount > 0 {
                        batchToggle(identifier: "toolBatchToggle")
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .assistantResponseSurface(tint: AgentPalette.primaryAccent)
            Spacer(minLength: 44)
        }
        .padding(.horizontal, 18)
    }

    private var detailRows: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(visibleToolCalls, id: \.id) { call in
                ToolActivityRow(
                    call: call,
                    showResultDetailByDefault: allToolCallsResolved && detailsExpanded && call.isError,
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

    private var allToolCallsResolved: Bool {
        !toolCalls.isEmpty && toolCalls.allSatisfy(\.isComplete)
    }

    private var primaryArtifact: WorkspaceArtifact? {
        toolCalls.compactMap(\.artifact).first
    }

    private var primaryTargetName: String? {
        if let primaryArtifact {
            return primaryArtifact.title
        }
        return toolCalls
            .map(\.detail)
            .map(Self.compactDisplayName)
            .first { !$0.isEmpty }
    }

    private var resolvedSummaryText: String {
        let target = primaryTargetName.map { " · \($0)" } ?? ""
        if failedToolCallCount > 0 {
            let completed = successfulToolCallCount > 0 ? " · \(successfulToolCallCount) completed" : ""
            return "\(failedToolCallCount) failed\(completed)\(target)"
        }
        let noun = toolCalls.count == 1 ? "action" : "actions"
        return "\(toolCalls.count) \(noun) completed\(target)"
    }

    private var resolvedSummarySymbol: String {
        failedToolCallCount > 0 ? "exclamationmark.triangle.fill" : "checkmark.circle.fill"
    }

    private var resolvedSummaryTint: Color {
        failedToolCallCount > 0 ? AgentPalette.rose : AgentPalette.green
    }

    private func toggleDetails() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        withAnimation(.smooth(duration: 0.18)) {
            detailsExpanded.toggle()
        }
    }


    private static func compactDisplayName(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let lastPathComponent = URL(fileURLWithPath: trimmed).lastPathComponent
        let display = lastPathComponent.isEmpty ? trimmed : lastPathComponent
        guard display.count > 68 else { return display }
        return String(display.prefix(68)) + "..."
    }

    private func batchToggle(identifier: String) -> some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            withAnimation(.smooth(duration: 0.18)) {
                detailsExpanded.toggle()
            }
        } label: {
            HStack(spacing: 7) {
                Image(systemName: detailsExpanded ? "chevron.up" : "ellipsis")
                    .font(.system(size: 10, weight: .bold))
                Text(detailsExpanded ? "Show fewer actions" : "\(hiddenToolCallCount) more actions")
                    .font(.system(size: 11, weight: .bold, design: AgentPalette.interfaceFontDesign))
                Spacer(minLength: 0)
            }
            .foregroundStyle(AgentPalette.secondaryText)
            .padding(.horizontal, 8)
            .frame(height: AgentDesign.minimumTouchTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(detailsExpanded ? "Show fewer actions" : "\(hiddenToolCallCount) more actions")
        .accessibilityIdentifier(identifier)
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

            Text(summary)
                .font(.system(size: 11.5, weight: .semibold, design: AgentPalette.interfaceFontDesign))
                .foregroundStyle(AgentPalette.secondaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
                .allowsTightening(true)
                .truncationMode(.tail)
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
                        .frame(width: AgentDesign.minimumTouchTarget, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
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
                    .foregroundStyle(AgentPalette.tertiaryText)
                    .frame(width: AgentDesign.minimumTouchTarget, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(detailsExpanded ? "Hide action details" : "Show action details")
            .accessibilityIdentifier("toolBatchToggle")
        }
        .padding(.horizontal, 2)
        .frame(minHeight: 28)
    }
}

private struct ToolActivityRow: View {
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
                        withAnimation(.smooth(duration: 0.18)) {
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
                Text(call.resultDetail)
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

    private var hasHiddenDetail: Bool {
        call.isComplete && !call.resultDetail.isEmpty
    }

    private var resultDetailVisible: Bool {
        showResultDetailByDefault || detailsExpanded
    }

    private var isWaitingForApprovalCandidate: Bool {
        !call.isComplete && [
            "write_file",
            "append_file",
            "replace_text",
            "run_command",
            "make_directory",
            "delete_path",
            "move_path",
            "copy_path"
        ].contains(call.name)
    }

    private var targetName: String? {
        guard !call.detail.isEmpty else { return nil }
        let trimmed = call.detail.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let lastPathComponent = URL(fileURLWithPath: trimmed).lastPathComponent
        let display = lastPathComponent.isEmpty ? trimmed : lastPathComponent
        return compactDetail(display)
    }

    private func compactDetail(_ text: String) -> String {
        let singleLine = text.replacingOccurrences(of: "\n", with: " ")
        guard singleLine.count > 82 else { return singleLine }
        return String(singleLine.prefix(82)) + "..."
    }

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

struct LiveResponseView: View {
    let isWorking: Bool
    let isHandoffActive: Bool
    @ObservedObject var stream: LiveStreamBuffer
    let runtime: AgentRuntime

    var body: some View {
        let _ = AgentPerformance.bodyEvaluation("Chat Live Response Body")
        Group {
            if isWorking || isHandoffActive {
                VStack(alignment: .leading, spacing: 10) {
                    // Reads runtime.activeToolName in its own tiny body, so
                    // tool changes re-render just this chip — never the chat.
                    if isWorking {
                        NovaLiveActivityPulse(runtime: runtime)
                    }

                    if stream.isEmpty {
                        if isWorking {
                            ThinkingView()
                        }
                    } else {
                        StreamingBubble(stream: stream)
                    }
                }
            }
        }
    }
}

/// Compact live-activity chip shown while the agent is using tools.
/// Observation is scoped: only this view re-renders when the active tool
/// changes.
private struct NovaLiveActivityPulse: View {
    let runtime: AgentRuntime

    var body: some View {
        if let toolName = runtime.activeToolName {
            HStack {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(AgentPalette.primaryAccent)

                    LiveShimmerText(
                        text: plainToolName(toolName),
                        baseColor: AgentPalette.secondaryText,
                        highlightColor: AgentPalette.ink,
                        font: .system(size: 12, weight: .semibold, design: AgentPalette.interfaceFontDesign)
                    )
                    .lineLimit(1)

                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(maxWidth: 300, alignment: .leading)
                .agentControlSurface(radius: 14, tint: AgentPalette.primaryAccent, selected: false)

                Spacer(minLength: 44)
            }
            .padding(.horizontal, 18)
            .transition(.opacity)
            .accessibilityLabel("Running \(plainToolName(toolName))")
            .accessibilityIdentifier("liveToolPulse")
        }
    }
}

/// Text with a soft highlight that sweeps across it — the "thinking shimmer".
/// Implemented as a phase-animated gradient mask over a brighter copy of the
/// text; a single tiny view, active only during live phases.
struct LiveShimmerText: View {
    let text: String
    let baseColor: Color
    let highlightColor: Color
    let font: Font

    var body: some View {
        let base = Text(text)
            .font(font)
            .foregroundStyle(baseColor)

        if AgentPerformance.allowsDecorativeMotion {
            base
                .overlay {
                    Text(text)
                        .font(font)
                        .foregroundStyle(highlightColor)
                        .mask {
                            GeometryReader { proxy in
                                let width = max(proxy.size.width, 1)
                                Rectangle()
                                    .fill(
                                        LinearGradient(
                                            colors: [.clear, .white, .clear],
                                            startPoint: .leading,
                                            endPoint: .trailing
                                        )
                                    )
                                    .frame(width: width * 0.6)
                                    .phaseAnimator([0.0, 1.0]) { content, phase in
                                        content.offset(x: -width * 0.6 + phase * (width + width * 0.6))
                                    } animation: { _ in
                                        .easeInOut(duration: 1.4)
                                    }
                            }
                        }
                }
        } else {
            base
        }
    }
}

private struct StreamingBubble: View {
    @ObservedObject var stream: LiveStreamBuffer
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var statusFlow = false

    private var allowsMotion: Bool {
        AgentPerformance.allowsDecorativeMotion && !reduceMotion
    }

    var body: some View {
        let _ = AgentPerformance.bodyEvaluation("Chat Streaming Bubble Body")
        HStack {
            LiquidMessageBubble(tint: AgentPalette.primaryAccent, isLive: true) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .top, spacing: 10) {
                        LiquidTypingAuraView(tint: AgentPalette.primaryAccent, compact: true)
                            .padding(.top, 1)
                            .accessibilityHidden(true)

                        StreamingTextView(text: stream.displayText)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    HStack(spacing: 7) {
                        LiveShimmerText(
                            text: "Liquid response",
                            baseColor: AgentPalette.tertiaryText,
                            highlightColor: AgentPalette.primaryAccent,
                            font: .system(size: 10, weight: .black, design: AgentPalette.interfaceFontDesign)
                        )
                        .lineLimit(1)
                        .accessibilityIdentifier("liveStreamingStatusText")

                        Capsule(style: .continuous)
                            .fill(AgentPalette.primaryAccent.opacity(0.28))
                            .frame(height: 1)
                            .overlay(alignment: .leading) {
                                Capsule(style: .continuous)
                                    .fill(AgentPalette.primaryAccent.opacity(allowsMotion ? 0.80 : 0.45))
                                    .frame(width: allowsMotion ? 54 : 28)
                                    .offset(x: allowsMotion ? (statusFlow ? 62 : -54) : 0)
                                    .animation(
                                        allowsMotion ? .easeInOut(duration: 1.55).repeatForever(autoreverses: true) : nil,
                                        value: statusFlow
                                    )
                            }
                    }
                    .accessibilityHidden(false)
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("liveStreamingReadableContent")
            Spacer(minLength: 44)
        }
        .padding(.horizontal, 18)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("liveStreamingBubble")
        .transaction { transaction in
            // Streaming text changes dozens of times per response. Animating
            // each append is expensive and can drag the live transcript below
            // the frame-rate gate; the glass chrome still carries the live
            // signal while text itself updates immediately.
            transaction.animation = nil
        }
        .onAppear { statusFlow = true }
    }
}

private struct StreamingTextView: View {
    let text: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var allowsMotion: Bool {
        AgentPerformance.allowsDecorativeMotion && !reduceMotion
    }

    var body: some View {
        Text(text.isEmpty ? " " : text)
            .foregroundStyle(AgentPalette.ink)
            .font(.system(size: 16, weight: .regular, design: AgentPalette.interfaceFontDesign))
            .lineSpacing(5)
            .textSelection(.enabled)
            .transaction { transaction in
                transaction.animation = nil
            }
    }
}

private struct LiquidMessageBubble<Content: View>: View {
    let tint: Color
    var isLive = false
    private let content: Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(tint: Color, isLive: Bool = false, @ViewBuilder content: () -> Content) {
        self.tint = tint
        self.isLive = isLive
        self.content = content()
    }

    private var allowsMotion: Bool {
        AgentPerformance.allowsDecorativeMotion && !reduceMotion
    }

    var body: some View {
        content
            .padding(.horizontal, 15)
            .padding(.vertical, 13)
            .frame(maxWidth: .infinity, alignment: .leading)
            .chatMessageSurface(radius: 22, tint: tint, emphasis: isLive ? .live : .assistant)
            .overlay {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(tint.opacity(isLive ? 0.42 : 0.24), lineWidth: isLive ? 0.95 : 0.65)
                    .blendMode(AgentTheme.current == .matrixRain ? .normal : .screen)
                    .allowsHitTesting(false)
            }
            .overlay {
                if isLive && allowsMotion {
                    LiquidSweepOverlay(tint: tint, radius: 22)
                }
            }
            .shadow(color: tint.opacity(isLive && !AgentPerformance.prefersReducedVisualEffects ? 0.10 : 0), radius: 14, x: 0, y: 5)
    }
}

private struct LiquidSweepOverlay: View {
    let tint: Color
    let radius: CGFloat
    @State private var flow = false

    var body: some View {
        GeometryReader { proxy in
            let width = max(proxy.size.width, 1)
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(.clear)
                .overlay(alignment: .leading) {
                    Rectangle()
                        .fill(
                            LinearGradient(
                                colors: [.clear, tint.opacity(0.16), .white.opacity(0.10), .clear],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .frame(width: max(72, width * 0.28))
                        .rotationEffect(.degrees(11))
                        .offset(x: flow ? width + 80 : -width * 0.45)
                        .animation(.easeInOut(duration: 2.8).repeatForever(autoreverses: false), value: flow)
                }
                .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        }
        .allowsHitTesting(false)
        .onAppear { flow = true }
    }
}

private struct ThinkingView: View {
    var body: some View {
        HStack {
            LiquidMessageBubble(tint: AgentPalette.primaryAccent, isLive: true) {
                HStack(spacing: 11) {
                    LiquidTypingAuraView(tint: AgentPalette.primaryAccent, compact: false)
                    VStack(alignment: .leading, spacing: 3) {
                        LiveShimmerText(
                            text: "Preparing response",
                            baseColor: AgentPalette.secondaryText,
                            highlightColor: AgentPalette.ink,
                            font: .system(size: 14, weight: .semibold, design: AgentPalette.interfaceFontDesign)
                        )
                        Text("Warming the local context and composing the first glass bubble")
                            .font(.system(size: 10.5, weight: .semibold, design: AgentPalette.interfaceFontDesign))
                            .foregroundStyle(AgentPalette.tertiaryText)
                            .lineLimit(1)
                            .minimumScaleFactor(0.72)
                    }
                    Spacer(minLength: 0)
                }
            }
            Spacer(minLength: 44)
        }
        .padding(.horizontal, 18)
        .accessibilityLabel("Assistant is preparing a response")
    }
}

private struct LiquidTypingAuraView: View {
    let tint: Color
    var compact = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var orbit = false

    private var allowsMotion: Bool {
        AgentPerformance.allowsDecorativeMotion && !reduceMotion
    }

    var body: some View {
        let size: CGFloat = compact ? 26 : 34
        ZStack {
            Circle()
                .fill(tint.opacity(0.12))
                .frame(width: size, height: size)
            Circle()
                .stroke(tint.opacity(0.24), lineWidth: 1)
                .frame(width: size - 3, height: size - 3)
            Circle()
                .trim(from: 0.12, to: 0.42)
                .stroke(tint.opacity(0.92), style: StrokeStyle(lineWidth: 2.1, lineCap: .round))
                .frame(width: size - 5, height: size - 5)
                .rotationEffect(.degrees(orbit ? 360 : 0))
                .animation(allowsMotion ? .linear(duration: 1.8).repeatForever(autoreverses: false) : nil, value: orbit)
            Circle()
                .fill(tint)
                .frame(width: compact ? 5 : 6, height: compact ? 5 : 6)
                .shadow(color: tint.opacity(allowsMotion ? 0.55 : 0.25), radius: compact ? 4 : 6)
        }
        .frame(width: size, height: size)
        .onAppear { orbit = true }
    }
}

/// Soft breathing orb used for the thinking state — a warmer, more alive
/// signal than a spinner.
private struct ThinkingOrb: View {
    let tint: Color

    var body: some View {
        let orb = ZStack {
            Circle()
                .fill(tint.opacity(0.24))
                .frame(width: 16, height: 16)
                .blur(radius: 3)
            Circle()
                .fill(tint.opacity(0.9))
                .frame(width: 8, height: 8)
        }

        if AgentPerformance.allowsDecorativeMotion {
            orb
                .phaseAnimator([0.82, 1.12, 0.82]) { content, phase in
                    content
                        .scaleEffect(phase)
                        .opacity(0.65 + (phase - 0.82) * 1.1)
                } animation: { _ in
                    .easeInOut(duration: 0.85)
                }
        } else {
            orb
        }
    }
}

private struct LiveSurfaceHeader: View {
    let title: String
    let subtitle: String
    let symbol: String
    let countText: String
    let tint: Color

    var body: some View {
        HStack(spacing: 9) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(tint.opacity(0.12))
                    .frame(width: 34, height: 34)
                Image(systemName: symbol)
                    .font(.system(size: 14, weight: .black))
                    .foregroundStyle(tint)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .black, design: AgentPalette.interfaceFontDesign))
                    .foregroundStyle(AgentPalette.ink)
                Text(subtitle)
                    .font(.system(size: 10, weight: .bold, design: AgentPalette.interfaceFontDesign))
                    .foregroundStyle(AgentPalette.tertiaryText)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            Text(countText)
                .font(.system(size: 9, weight: .black, design: AgentPalette.interfaceFontDesign))
                .foregroundStyle(tint)
                .padding(.horizontal, 8)
                .frame(height: 24)
                .agentControlSurface(radius: 8, tint: tint.opacity(0.12), selected: true)
        }
    }
}

private struct NeuralActivityRail: View {
    let tint: Color
    let animated: Bool

    var body: some View {
        let rail = RoundedRectangle(cornerRadius: 3, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [tint.opacity(0.85), AgentPalette.secondaryAccent.opacity(0.45), AgentPalette.primaryAccent.opacity(0.60)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .frame(width: 4)

        if animated && AgentPerformance.allowsDecorativeMotion {
            rail
                .phaseAnimator([0.35, 1.0, 0.35]) { content, phase in
                    content.opacity(phase)
                } animation: { phase in
                    phase == 1.0 ? .easeInOut(duration: 0.7) : .easeInOut(duration: 0.55)
                }
        } else {
            rail.opacity(0.78)
        }
    }
}

private struct StatusDots: View {
    let tint: Color
    let animated: Bool

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { index in
                let dot = Circle()
                    .fill(tint.opacity(index == 0 ? 0.85 : 0.36))
                    .frame(width: 5, height: 5)

                if animated && AgentPerformance.allowsDecorativeMotion {
                    dot
                        .phaseAnimator([0.42, 1.0, 0.42], trigger: index) { dot, phase in
                            dot.scaleEffect(phase)
                                .opacity(0.55 + phase * 0.45)
                        } animation: { phase in
                            phase == 1.0 ? .easeInOut(duration: 0.34).delay(Double(index) * 0.08) : .easeInOut(duration: 0.42)
                        }
                } else {
                    dot
                }
            }
        }
    }
}

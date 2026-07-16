import AgentPolicy
import AgentTools
import SwiftData
import SwiftUI

struct TerminalOutputLine: Identifiable, Hashable, Sendable {
    let id: UUID
    let command: String
    let output: String
    let outputLineCount: Int
    let previewOutputLines: [String]
    let detailOutputLines: [String]
    let isError: Bool
    let timestamp: Date
    let durationMs: Double

    init(command: String, output: String, isError: Bool, durationMs: Double, id: UUID = UUID(), timestamp: Date = Date()) {
        self.id = id
        self.command = command
        let storedOutput = Self.cappedOutput(output)
        self.output = storedOutput
        let source = storedOutput.isEmpty ? "[no output]" : storedOutput
        var lineCount = 0
        var collectedLines: [String] = []
        collectedLines.reserveCapacity(80)
        source.enumerateLines { line, _ in
            lineCount += 1
            if collectedLines.count < 80 {
                collectedLines.append(line)
            }
        }
        if lineCount == 0 {
            lineCount = 1
            collectedLines = [source]
        }
        self.outputLineCount = lineCount
        self.previewOutputLines = Array(collectedLines.prefix(8))
        self.detailOutputLines = collectedLines
        self.isError = isError
        self.timestamp = timestamp
        self.durationMs = durationMs
    }

    init(record: TerminalCommandRecord) {
        self.init(
            command: record.command,
            output: record.output,
            isError: record.status == .failed,
            durationMs: record.durationMs,
            id: record.id,
            timestamp: record.completedAt
        )
    }

    private static func cappedOutput(_ output: String) -> String {
        let maxCharacters = 40_000
        guard output.count > maxCharacters else { return output }
        return String(output.prefix(maxCharacters)) + "\n… truncated in terminal history for smooth scrolling. Use a narrower command or file preview for more."
    }

    var hasHiddenDetails: Bool {
        outputLineCount > previewOutputLines.count
    }

    var collapsedHiddenLineCount: Int {
        max(outputLineCount - previewOutputLines.count, 0)
    }

    var hiddenOutputLineCount: Int {
        max(outputLineCount - detailOutputLines.count, 0)
    }

    var durationText: String {
        String(format: "%.0fms", durationMs)
    }

    var relativeTimestampText: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: timestamp, relativeTo: Date())
    }
}

extension TerminalOutputLine: TerminalConsoleSearchableLineRepresenting {}

private struct TerminalCommandExecutionOutcome: Sendable {
    let output: String
    let isError: Bool
    let mutationDurablyCompleted: Bool
    let mutationMayHaveApplied: Bool
    let mutationOperationID: UUID?
}

private struct TerminalPolicyMutationDispatch: Sendable {
    let coordinator: AgentPolicyMutationCoordinator
    let context: AgentPolicyMutationExecutionContext
    let operationID: UUID
}

private extension TerminalCommandDraft {
    /// Terminal mutation output is intentionally reconstructed from the
    /// already-visible, validated draft. The policy coordinator returns only a
    /// digest receipt, so this text is published only after that receipt and
    /// never by executing the command a second time.
    var completedMutationSummary: String {
        let arguments = Array(tokens.dropFirst())
        switch commandName {
        case "mkdir":
            return "Created \(arguments.first ?? "path")"
        case "touch":
            return "Touched \(arguments.first ?? "path")"
        case "rm":
            return "Removed \(arguments.first ?? "path")"
        case "mv":
            guard arguments.count == 2 else { return "Move completed" }
            return "Moved \(arguments[0]) to \(arguments[1])"
        case "cp":
            guard arguments.count == 2 else { return "Copy completed" }
            return "Copied \(arguments[0]) to \(arguments[1])"
        default:
            return "Workspace command completed"
        }
    }
}

private extension AgentPolicyMutationServiceError {
    var terminalEffectMayHaveApplied: Bool {
        switch self {
        case .effectFailed, .recoveryFailed:
            true
        case .invalidComposition, .cancelled, .requestRejected,
             .policyDenied, .policyIndeterminate, .approvalRejected,
             .approvalFailed, .authorizationFailed, .claimFailed,
             .stagedAutomaticAuthorizationUnsupported,
             .stagedPreparationMismatch, .approvalBindingMismatch:
            false
        }
    }
}

struct TerminalConsoleFocusRequest: Identifiable, Equatable {
    let id: UUID
    let command: String
    let query: String
}

struct TerminalConsoleView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var terminalRecords: [TerminalCommandRecord]

    var runtime: AgentRuntime
    var project: Project
    let openChat: () -> Void
    let initialFocus: TerminalConsoleFocusRequest?
    let close: (() -> Void)?

    @State private var inputCommand = ""
    @State private var consoleLines: [TerminalOutputLine] = []
    @State private var commandHistory: [String] = []
    @State private var showingHistorySheet = false
    @State private var isExecuting = false

    @State private var consoleFontSize: CGFloat = 11
    @State private var isSearchExpanded = false
    @State private var searchQuery = ""
    @State private var debouncedSearchQuery = ""
    @State private var filteredConsoleLines: [TerminalOutputLine] = []
    @State private var matchingCommands: [String] = []
    @State private var expandedLineIDs: Set<UUID> = []
    @State private var focusedLineID: UUID?
    @State private var pendingScrollLineID: UUID?
    @State private var appliedFocusID: UUID?
    @State private var hasSeededTerminalStress = false
    @State private var commandTask: Task<Void, Never>?
    @State private var activeCommandExecutionID: UUID?
    @State private var copiedOutputLineID: UUID?
    @State private var copyFeedbackTask: Task<Void, Never>?
    @State private var terminalSaveError: String?
    @FocusState private var commandFocused: Bool

    private static let searchableOutputLimit = 2_000
    private static let maxHistoryCount = 80
    private static let maxConsoleLineCount = 80
    private let terminalBottomClearance: CGFloat = BottomDockMetrics.terminalScrollClearance
    private let terminalCommandButtonHeight: CGFloat = AgentDesign.minimumTouchTarget + 1

    private var missionContract: MissionOSContract {
        ProjectMissionSummarizer.summarize(project: project, context: modelContext).missionContract
    }

    init(
        runtime: AgentRuntime,
        project: Project,
        openChat: @escaping () -> Void,
        initialFocus: TerminalConsoleFocusRequest? = nil,
        close: (() -> Void)? = nil
    ) {
        self.runtime = runtime
        self.project = project
        self.openChat = openChat
        self.initialFocus = initialFocus
        self.close = close
    }

    var body: some View {
        VStack(spacing: 12) {
            header

            consoleDisplay
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 8) {
                commandSafetyStrip
                autocompleteBar
                commandComposer
            }
            .padding(.top, 8)
            .background {
                UnevenRoundedRectangle(topLeadingRadius: 26, topTrailingRadius: 26)
                    .fill(.ultraThinMaterial)
                    .background(
                        UnevenRoundedRectangle(topLeadingRadius: 26, topTrailingRadius: 26)
                            .fill(AgentPalette.surface.opacity(commandFocused ? 1.0 : 0.92))
                    )
                    .overlay(
                        UnevenRoundedRectangle(topLeadingRadius: 26, topTrailingRadius: 26)
                            .stroke(AgentPalette.blue.opacity(commandFocused ? 0.20 : 0.10), lineWidth: 1)
                    )
                    .ignoresSafeArea(edges: .bottom)
            }
        }
        .sheet(isPresented: $showingHistorySheet) {
            historySheet
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .alert(
            "Terminal Proof Not Saved",
            isPresented: Binding(
                get: { terminalSaveError != nil },
                set: { if !$0 { terminalSaveError = nil } }
            )
        ) {
            Button("OK", role: .cancel) { terminalSaveError = nil }
        } message: {
            Text(terminalSaveError ?? "The command ran, but NovaForge could not save its terminal proof record.")
        }
        .onAppear {
            syncConsoleWithProjectRecords()
            seedTerminalStressIfNeeded()
            #if DEBUG
            seedTerminalSafetyDemoIfNeeded()
            seedTerminalUnsupportedDemoIfNeeded()
            #endif
            updateFilteredConsoleLines()
            updateMatchingCommands()
        }
        .onChange(of: searchQuery) {
            let value = searchQuery
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(160))
                guard value == searchQuery else { return }
                debouncedSearchQuery = value
            }
        }
        .onChange(of: debouncedSearchQuery) {
            updateFilteredConsoleLines()
        }
        .onChange(of: inputCommand) {
            updateMatchingCommands()
        }
        .onChange(of: consoleLines) {
            updateFilteredConsoleLines()
        }
        .onChange(of: terminalRecords.count) {
            syncConsoleWithProjectRecords()
        }
        .onChange(of: project.id) {
            replaceConsoleWithProjectRecords()
        }
        .onDisappear {
            commandTask?.cancel()
            commandTask = nil
            activeCommandExecutionID = nil
            copyFeedbackTask?.cancel()
            copyFeedbackTask = nil
            isExecuting = false
        }
        .animation(.smooth(duration: 0.24), value: commandFocused)
    }
    
    private var header: some View {
        VStack(spacing: 10) {
            NovaScreenHeader(
                kicker: "Scoped Proof Surface",
                title: "Terminal",
                subtitle: terminalHeaderStatusLine,
                symbol: "terminal",
                tint: AgentPalette.lilac,
                isActive: isExecuting,
                showsGlyph: false
            ) {
                HStack(spacing: 8) {
                    terminalHeaderButton(
                        symbol: "magnifyingglass",
                        tint: AgentPalette.lilac,
                        selected: isSearchExpanded,
                        label: isSearchExpanded ? "Hide terminal search" : "Show terminal search",
                        identifier: "terminalSearchToggle"
                    ) {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                            isSearchExpanded.toggle()
                        }
                    }

                    terminalHeaderButton(
                        symbol: "trash",
                        tint: AgentPalette.rose,
                        selected: false,
                        label: "Clear terminal console",
                        identifier: "terminalClearConsoleButton",
                        action: clearConsole
                    )

                    if let close {
                        terminalHeaderButton(
                            symbol: "xmark",
                            tint: AgentPalette.secondaryText,
                            selected: false,
                            label: "Close terminal",
                            identifier: "terminalCloseButton",
                            action: close
                        )
                    }
                }
            }

            commandDeckOverview

            terminalProofSummaryStrip

            if runtime.shouldShowWorkspaceStatusStrip {
                WorkspaceStatusStrip(runtime: runtime, openChat: openChat)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }

            if isSearchExpanded {
                HStack(spacing: 12) {
                    TextField("Filter console log lines...", text: $searchQuery)
                        .textFieldStyle(.plain)
                        .padding(.horizontal, 12)
                        .frame(minHeight: AgentDesign.minimumTouchTarget)
                        .agentControlSurface(radius: 10, tint: AgentPalette.lilac)
                        .accessibilityIdentifier("terminalConsoleSearchField")
                    
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Font Size: \(Int(consoleFontSize))")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(AgentPalette.secondaryText)
                        Slider(value: $consoleFontSize, in: 8...16, step: 1)
                            .frame(width: 80)
                            .accessibilityIdentifier("terminalConsoleFontSizeSlider")
                    }
                }
                .padding(.horizontal, 4)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .padding(.horizontal)
        .padding(.top, 14)
    }

    private var commandDeckOverview: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 7) {
                Text("\(TerminalCommandCatalog.supportedCommands.count) CMDS")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .tracking(1.0)
                    .foregroundStyle(AgentPalette.lilac.opacity(0.85))
                    .padding(.trailing, 3)
                    .accessibilityLabel("\(TerminalCommandCatalog.supportedCommands.count) scoped commands")

                ForEach(TerminalCommandCatalog.presetCommands, id: \.command) { suggestion in
                    terminalPresetButton(suggestion)
                }
                Rectangle()
                    .fill(AgentPalette.divider.opacity(0.6))
                    .frame(width: 1, height: 20)
                    .padding(.horizontal, 3)
                ForEach(TerminalCommandCatalog.quickCheckCommands, id: \.command) { suggestion in
                    terminalQuickCheckButton(suggestion)
                }
            }
            .padding(.vertical, 2)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("terminalQuickChecks")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("terminalCommandDeck")
    }

    private var terminalHeaderStatusLine: String {
        let workspaceName = runtime.workspace.workspaceName
        if consoleLines.isEmpty {
            return "\(workspaceName) · scoped to the workspace"
        }
        var parts = ["\(workspaceName)", "\(consoleLines.count) record\(consoleLines.count == 1 ? "" : "s")"]
        if !debouncedSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append("\(filteredConsoleLines.count) match\(filteredConsoleLines.count == 1 ? "" : "es")")
        }
        if commandHistory.count > 0 {
            parts.append("\(commandHistory.count) in history")
        }
        return parts.joined(separator: " · ")
    }

    private var terminalProofSummaryStrip: some View {
        HStack(spacing: 9) {
            terminalProofMetric(
                value: "\(consoleLines.count)",
                label: "Receipts",
                symbol: "terminal.fill",
                tint: AgentPalette.lilac
            )
            terminalProofMetric(
                value: "\(consoleLines.filter { $0.isError }.count)",
                label: "Failures",
                symbol: "xmark.octagon.fill",
                tint: consoleLines.contains(where: \.isError) ? AgentPalette.rose : AgentPalette.green
            )
            terminalProofMetric(
                value: latestTerminalDurationText,
                label: "Latest",
                symbol: "timer",
                tint: AgentPalette.cyan
            )
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .agentSurface(radius: 16, tint: AgentPalette.lilac.opacity(0.08))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("terminalProofSummary")
    }

    private var latestTerminalDurationText: String {
        guard let latest = consoleLines.last else { return "--" }
        return latest.durationText
    }

    private func terminalProofMetric(value: String, label: String, symbol: String, tint: Color) -> some View {
        HStack(spacing: 7) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .black))
                .foregroundStyle(tint)

            VStack(alignment: .leading, spacing: 1) {
                Text(value)
                    .font(.system(size: 13, weight: .black, design: AgentPalette.interfaceFontDesign))
                    .foregroundStyle(AgentPalette.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                Text(label)
                    .font(.system(size: 7.5, weight: .black, design: AgentPalette.interfaceFontDesign))
                    .foregroundStyle(AgentPalette.secondaryText)
                    .textCase(.uppercase)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func terminalHeaderButton(
        symbol: String,
        tint: Color,
        selected: Bool,
        label: String,
        identifier: String,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            NovaHaptics.tick()
            action()
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(selected ? AgentPalette.ink : tint)
                .frame(
                    width: AgentDesign.minimumTouchTarget,
                    height: AgentDesign.minimumTouchTarget
                )
                .background(
                    Circle()
                        .fill(tint.opacity(selected ? 0.26 : 0.10))
                )
                .overlay(
                    Circle()
                        .strokeBorder(tint.opacity(selected ? 0.5 : 0.24), lineWidth: 0.9)
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityIdentifier(identifier)
    }

    private func terminalPresetButton(_ suggestion: TerminalCommandSuggestion) -> some View {
        terminalDeckChip(suggestion, tint: AgentPalette.cyan, kind: "preset")
    }

    private func terminalQuickCheckButton(_ suggestion: TerminalCommandSuggestion) -> some View {
        terminalDeckChip(suggestion, tint: AgentPalette.lilac, kind: "quick check")
    }

    /// Mono command capsule — prompt glyph + command text, terminal-native.
    private func terminalDeckChip(_ suggestion: TerminalCommandSuggestion, tint: Color, kind: String) -> some View {
        Button {
            NovaHaptics.tick()
            inputCommand = suggestion.command
            commandFocused = true
        } label: {
            HStack(spacing: 6) {
                Text("$")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(tint.opacity(0.85))
                Text(suggestion.label)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(AgentPalette.ink)
                    .lineLimit(1)
            }
            .padding(.horizontal, 12)
            .frame(height: terminalCommandButtonHeight)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .background(Capsule(style: .continuous).fill(tint.opacity(0.09)))
        .overlay(Capsule(style: .continuous).strokeBorder(tint.opacity(0.24), lineWidth: 0.8))
        .accessibilityLabel("Use terminal \(kind) \(suggestion.command). \(suggestion.detail)")
        .accessibilityIdentifier("terminal\(kind == "preset" ? "Preset" : "QuickCheck")-\(suggestion.command.replacingOccurrences(of: " ", with: "-"))")
    }

    private func outputActionRow(for line: TerminalOutputLine, isExpanded: Bool) -> some View {
        HStack(spacing: 8) {
            Label("\(line.outputLineCount) line\(line.outputLineCount == 1 ? "" : "s")", systemImage: "text.alignleft")
                .font(.system(size: 8.5, weight: .black, design: AgentPalette.interfaceFontDesign))
                .foregroundStyle(AgentPalette.cyan)
                .lineLimit(1)
                .padding(.horizontal, 8)
                .frame(height: 30)
                .agentControlSurface(radius: 9, tint: AgentPalette.cyan.opacity(0.10), selected: true)

            if line.hasHiddenDetails {
                Button {
                    toggleOutputDetails(line.id)
                } label: {
                    Label(
                        isExpanded ? "Collapse" : "Details",
                        systemImage: isExpanded ? "chevron.up" : "text.page"
                    )
                    .font(.system(size: 9, weight: .black, design: AgentPalette.interfaceFontDesign))
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
                    .foregroundStyle(AgentPalette.ink)
                    .padding(.horizontal, 9)
                    .frame(minHeight: AgentDesign.minimumTouchTarget)
                    .agentControlSurface(radius: 9, tint: AgentPalette.lilac.opacity(0.18), selected: true)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isExpanded ? "Collapse terminal output" : "Show terminal output details")
                .accessibilityIdentifier(isExpanded ? "terminalOutputCollapse" : "terminalOutputExpand")
            }

            Spacer(minLength: 0)

            Button {
                copyOutput(line)
            } label: {
                Label(
                    copiedOutputLineID == line.id ? "Copied" : "Copy",
                    systemImage: copiedOutputLineID == line.id ? "checkmark" : "doc.on.doc"
                )
                .font(.system(size: 9, weight: .black, design: AgentPalette.interfaceFontDesign))
                .lineLimit(1)
                .foregroundStyle(AgentPalette.ink)
                .padding(.horizontal, 9)
                .frame(minHeight: AgentDesign.minimumTouchTarget)
                .agentControlSurface(radius: 9, tint: AgentPalette.cyan.opacity(0.18), selected: true)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(copiedOutputLineID == line.id ? "Terminal output copied" : "Copy terminal output")
            .accessibilityIdentifier("terminalCopyOutput")
        }
    }

    private func terminalRecordHeader(for line: TerminalOutputLine, isFocused: Bool) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: line.isError ? "xmark.octagon.fill" : "checkmark.seal.fill")
                .font(.system(size: 13, weight: .black))
                .foregroundStyle(line.isError ? AgentPalette.rose : AgentPalette.green)
                .frame(width: 34, height: 34)
                .agentControlSurface(
                    radius: 11,
                    tint: (line.isError ? AgentPalette.rose : AgentPalette.green).opacity(0.12),
                    selected: true
                )

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text("Command proof")
                        .font(.system(size: 8.5, weight: .black, design: AgentPalette.interfaceFontDesign))
                        .foregroundStyle(line.isError ? AgentPalette.rose : AgentPalette.cyan)
                        .textCase(.uppercase)
                        .tracking(0.8)
                    if isFocused {
                        StatusChip(text: "FOCUS", symbol: "link", tint: AgentPalette.lilac)
                            .accessibilityLabel("Focused terminal proof")
                            .accessibilityIdentifier("terminalFocusedRecord")
                    }
                }

                Text("$ \(line.command)")
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .foregroundStyle(AgentPalette.cyan)
                    .lineLimit(2)
                    .truncationMode(.middle)

                HStack(spacing: 7) {
                    terminalMetaPill(line.isError ? "Failed" : "Completed", symbol: line.isError ? "xmark.circle.fill" : "checkmark.circle.fill", tint: line.isError ? AgentPalette.rose : AgentPalette.green)
                    terminalMetaPill(line.durationText, symbol: "timer", tint: AgentPalette.lilac)
                    terminalMetaPill(line.relativeTimestampText, symbol: "clock.fill", tint: AgentPalette.secondaryText)
                }
            }

            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Terminal command \(line.command), \(line.isError ? "failed" : "completed"), \(line.outputLineCount) output lines")
    }

    private func terminalMetaPill(_ text: String, symbol: String, tint: Color) -> some View {
        Label(text, systemImage: symbol)
            .font(.system(size: 8, weight: .black, design: AgentPalette.interfaceFontDesign))
            .foregroundStyle(tint)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 6)
            .frame(height: 20)
            .agentControlSurface(radius: 7, tint: tint.opacity(0.09), selected: true)
    }
    
    private var consoleDisplay: some View {
        ScrollViewReader { proxy in
            ZStack(alignment: .bottomTrailing) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        if consoleLines.isEmpty {
                            // Fill the console viewport so an empty tty
                            // reads as a terminal, not a card floating over
                            // half a screen of dead space.
                            terminalEmptyState
                                .containerRelativeFrame(.vertical) { length, _ in
                                    max(320, length * 0.86)
                                }
                        } else if filteredConsoleLines.isEmpty {
                            terminalSearchEmptyState
                        } else {
                            ForEach(filteredConsoleLines) { line in
                                let isExpanded = expandedLineIDs.contains(line.id)
                                let isFocused = focusedLineID == line.id
                                VStack(alignment: .leading, spacing: 8) {
                                    terminalRecordHeader(for: line, isFocused: isFocused)
                                    outputActionRow(for: line, isExpanded: isExpanded)

                                    ConsoleLogLineView(
                                        line: line,
                                        fontSize: consoleFontSize,
                                        isExpanded: isExpanded
                                    )
                                        .textSelection(.enabled)
                                        .padding(10)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .background(AgentPalette.terminalBackground.opacity(0.92), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                                .stroke((line.isError ? AgentPalette.rose : AgentPalette.cyan).opacity(0.24), lineWidth: 0.8)
                                        )
                                }
                                .padding(12)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .agentRowSurface(radius: 16, tint: line.isError ? AgentPalette.rose : AgentPalette.cyan, selected: line.isError || isFocused)
                                .accessibilityElement(children: .contain)
                                .accessibilityIdentifier("terminalOutputRecord")
                                .id(line.id)
                            }
                        }
                    }
                    .padding(.horizontal)
                    .padding(.bottom, terminalBottomClearance)
                }
                .scrollContentBackground(.hidden)
                .scrollDismissesKeyboard(.interactively)
                .contentShape(Rectangle())
                .onTapGesture {
                    commandFocused = false
                }
            }
            .onChange(of: consoleLines.count) {
                if let last = consoleLines.last {
                    withAnimation(.smooth(duration: 0.25)) {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
            .onChange(of: pendingScrollLineID, initial: true) { _, newValue in
                guard let newValue else { return }
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(180))
                    withAnimation(.smooth(duration: 0.24)) {
                        proxy.scrollTo(newValue, anchor: .center)
                    }
                    pendingScrollLineID = nil
                }
            }
        }
    }

    /// The console-boot moment: a mono session block rendered like real
    /// terminal output, with a live prompt and blinking cursor waiting
    /// for the first command.
    private var terminalEmptyState: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                ForEach(0..<3, id: \.self) { index in
                    Circle()
                        .fill(AgentPalette.terminalPrompt.opacity(index == 0 ? 0.85 : 0.28))
                        .frame(width: 7, height: 7)
                }
                Spacer(minLength: 8)
                Text("tty · \(runtime.workspace.workspaceName)")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(AgentPalette.terminalOutput.opacity(0.75))
            }
            .padding(.bottom, 14)

            Group {
                Text("NOVAFORGE PROOF SHELL")
                    .font(.system(size: 13, weight: .heavy, design: .monospaced))
                    .foregroundStyle(AgentPalette.terminalPrompt)
                    .tracking(2.2)
                Text("session scoped to the active workspace — nothing outside it can be touched")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(AgentPalette.terminalOutput)
                    .padding(.top, 3)
            }

            VStack(alignment: .leading, spacing: 7) {
                terminalBootHint(command: "ls", note: "list workspace root")
                terminalBootHint(command: "find . -name \"*.md\"", note: "locate files by pattern")
                terminalBootHint(command: "wc -l README.md", note: "capture countable proof")
            }
            .padding(.top, 16)

            HStack(spacing: 8) {
                Text("$")
                    .font(.system(size: 14, weight: .bold, design: .monospaced))
                    .foregroundStyle(AgentPalette.terminalPrompt)
                TerminalBlinkingCursor()
            }
            .padding(.top, 18)
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            AgentPalette.terminalBackground.opacity(0.94),
            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(AgentPalette.terminalPrompt.opacity(0.22), lineWidth: 0.8)
        )
        .overlay(NovaCornerTicks(tint: AgentPalette.terminalPrompt.opacity(0.4), length: 8, thickness: 1.2, inset: 6))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Terminal is empty. Pick a preset above or type a safe command below. Terminal is a scoped proof surface.")
        .accessibilityIdentifier("terminalEmptyState")
    }

    private func terminalBootHint(command: String, note: String) -> some View {
        Button {
            NovaHaptics.tick()
            inputCommand = command
            commandFocused = true
        } label: {
            HStack(spacing: 9) {
                Text("›")
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundStyle(AgentPalette.terminalPrompt.opacity(0.6))
                Text(command)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(AgentPalette.terminalCommand)
                Text("· \(note)")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(AgentPalette.terminalOutput.opacity(0.7))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Use command \(command). \(note)")
    }

    private var terminalSearchEmptyState: some View {
        NovaOrbitalEmptyState(
            symbol: "magnifyingglass",
            title: "No output matches",
            detail: "Clear the console filter or search for a command, path, warning, or proof line.",
            tint: AgentPalette.lilac
        )
        .accessibilityIdentifier("terminalSearchEmptyState")
    }
    
    private var commandSafetyStrip: some View {
        Group {
            if !trimmedInputCommand.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: draftSafetySymbol)
                        .font(.system(size: 10, weight: .black))
                        .foregroundStyle(draftSafetyTint)
                        .frame(width: 24, height: 24)
                        .agentControlSurface(radius: 8, tint: draftSafetyTint.opacity(0.10), selected: true)

                    VStack(alignment: .leading, spacing: 1) {
                        Text(draftSafetyTitle)
                            .font(.system(size: 10, weight: .black, design: AgentPalette.interfaceFontDesign))
                            .foregroundStyle(AgentPalette.ink)
                            .accessibilityIdentifier("terminalCommandSafetyLabel")
                        Text(draftSafetyDetail)
                            .font(.system(size: 8.5, weight: .semibold, design: AgentPalette.interfaceFontDesign))
                            .foregroundStyle(AgentPalette.secondaryText)
                            .lineLimit(1)
                            .minimumScaleFactor(0.78)
                            .accessibilityIdentifier("terminalCommandSafetyDetail")
                    }

                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .agentRowSurface(radius: 14, tint: draftSafetyTint.opacity(0.07), selected: draftCommandIsMutating)
                .padding(.horizontal)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("terminalCommandSafetyStrip")
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }

    private var autocompleteBar: some View {
        Group {
            if !matchingCommands.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(matchingCommands, id: \.self) { suggestion in
                            Button {
                                inputCommand = suggestion + " "
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: "terminal.fill")
                                        .font(.caption2)
                                        .foregroundStyle(AgentPalette.cyan)
                                    Text(suggestion)
                                        .font(.system(.caption, design: .monospaced, weight: .bold))
                                }
                                .padding(.horizontal, 10)
                                .frame(minWidth: AgentDesign.minimumTouchTarget, minHeight: terminalCommandButtonHeight)
                                .agentControlSurface(radius: 10, tint: AgentPalette.cyan, selected: true)
                            }
                            .buttonStyle(.plain)
                            .contentShape(Rectangle())
                            .accessibilityLabel("Use terminal suggestion \(suggestion)")
                            .accessibilityIdentifier("terminalAutocomplete-\(suggestion.replacingOccurrences(of: " ", with: "-"))")
                        }
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 4)
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }
    
    private var commandComposer: some View {
        HStack(spacing: 8) {
            Text("$")
                .font(.system(.body, design: .monospaced, weight: .bold))
                .foregroundStyle(AgentPalette.cyan)
                .padding(.leading, 12)
            
            ZStack(alignment: .leading) {
                if inputCommand.isEmpty {
                    HStack(spacing: 2) {
                        Text("run command...")
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(AgentPalette.tertiaryText)
                        
                        Rectangle()
                            .fill(AgentPalette.cyan)
                            .frame(width: 8, height: 14)
                            .opacity(0.55)
                    }
                }
                
                TextField("", text: $inputCommand)
                    .font(.system(.body, design: .monospaced))
                    .textFieldStyle(.plain)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.none)
                    .focused($commandFocused)
                    .onSubmit(runCommand)
                    .disabled(isExecuting)
                    .accessibilityIdentifier("terminalCommandInput")
            }
            
            Button {
                let impact = UIImpactFeedbackGenerator(style: .light)
                impact.impactOccurred()
                showingHistorySheet = true
            } label: {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 14, weight: .bold))
                        .frame(width: AgentDesign.minimumTouchTarget, height: AgentDesign.minimumTouchTarget)
                    
                    if !commandHistory.isEmpty {
                        Text("\(commandHistory.count)")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(AgentPalette.ink)
                            .padding(4)
                            .background(AgentPalette.cyan, in: Circle())
                            .offset(x: 4, y: -4)
                    }
                }
            }
            .buttonStyle(.plain)
            .agentControlSurface(radius: 12, tint: AgentPalette.cyan)
            .accessibilityLabel("Command history")
            .accessibilityIdentifier("terminalHistoryButton")
                
            Button(action: runCommand) {
                if isExecuting {
                    Image(systemName: "hourglass")
                        .font(.system(size: 15, weight: .bold))
                    .frame(width: AgentDesign.minimumTouchTarget, height: AgentDesign.minimumTouchTarget)
                } else {
                    Image(systemName: "play.fill")
                        .font(.system(size: 14, weight: .bold))
                        .frame(width: AgentDesign.minimumTouchTarget, height: AgentDesign.minimumTouchTarget)
                }
            }
            .disabled(!canRunDraftCommand)
            .buttonStyle(.plain)
            .agentControlSurface(radius: 12, tint: AgentPalette.cyan, selected: true)
            .accessibilityLabel(terminalRunAccessibilityLabel)
            .accessibilityIdentifier("terminalRunButton")
        }
        .padding(.vertical, 4)
        .padding(.trailing, 4)
        .agentSurface(radius: 16, tint: commandFocused ? AgentPalette.cyan.opacity(0.10) : nil)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("terminalCommandComposer")
        .padding(.horizontal)
        .padding(.bottom, commandFocused ? 8 : 12)
    }
    
    private var trimmedInputCommand: String {
        inputCommand.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var commandDraft: TerminalCommandDraft {
        TerminalCommandDraft(trimmedInputCommand)
    }

    private var draftCommandName: String? {
        commandDraft.commandName
    }

    private var draftCommandIsKnown: Bool {
        commandDraft.isKnown
    }

    private var draftCommandIsMutating: Bool {
        commandDraft.isMutating
    }

    private var canRunDraftCommand: Bool {
        guard !isExecuting else { return false }
        return commandDraft.canRun
    }

    private var terminalRunAccessibilityLabel: String {
        guard draftCommandName != nil else { return "Run terminal command" }
        if !draftCommandIsKnown { return "Unsupported terminal command" }
        if commandDraft.argumentIssue != nil { return "Fix terminal command arguments" }
        return draftCommandIsMutating ? "Review file-changing command" : "Run terminal command"
    }

    private var draftSafetyTitle: String {
        guard draftCommandName != nil else { return "Ready" }
        if !draftCommandIsKnown { return "Unsupported command" }
        if commandDraft.argumentIssue != nil { return "Check arguments" }
        return draftCommandIsMutating ? "Changes files" : "Read-only command"
    }

    private var draftSafetyDetail: String {
        commandDraft.guidance
    }

    private var draftSafetySymbol: String {
        if !draftCommandIsKnown { return "nosign" }
        if commandDraft.argumentIssue != nil { return "exclamationmark.triangle.fill" }
        return draftCommandIsMutating ? "exclamationmark.shield.fill" : "checkmark.shield.fill"
    }

    private var draftSafetyTint: Color {
        if !draftCommandIsKnown { return AgentPalette.rose }
        if commandDraft.argumentIssue != nil { return AgentPalette.rose }
        return draftCommandIsMutating ? AgentPalette.lilac : AgentPalette.green
    }

    private func runCommand() {
        guard !isExecuting else { return }
        let cmd = trimmedInputCommand
        let draft = TerminalCommandDraft(cmd)
        guard draft.canRun else { return }
        if draft.isMutating {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }
        executeCommand(cmd)
    }

    @MainActor
    private func executeCommand(_ cmd: String) {
        inputCommand = ""
        commandFocused = false
        if !commandHistory.contains(cmd) {
            commandHistory.append(cmd)
            if commandHistory.count > Self.maxHistoryCount {
                commandHistory.removeFirst(commandHistory.count - Self.maxHistoryCount)
            }
        }
        isExecuting = true
        let startTime = Date()

        let workspace = runtime.workspace
        let draft = TerminalCommandDraft(cmd)
        let isMutating = draft.isMutating
        let projectID = project.id
        let conversationID = runtime.activeConversationID
        let mutationOperationID = isMutating ? UUID() : nil
        let mutationDispatch: TerminalPolicyMutationDispatch?
        let mutationPreparationError: String?

        if let mutationOperationID {
            do {
                let policyRuntime = AgentPolicyMutationRuntime.shared
                let context = try policyRuntime.makeExecutionContext(
                    workspace: workspace,
                    operationID: mutationOperationID,
                    idempotencyKey: Self.terminalMutationIdempotencyKey(
                        operationID: mutationOperationID
                    ),
                    conversationID: conversationID,
                    projectID: projectID,
                    acceptedAt: startTime,
                    sessionID: "terminal"
                )
                mutationDispatch = TerminalPolicyMutationDispatch(
                    coordinator: try policyRuntime.coordinator(),
                    context: context,
                    operationID: mutationOperationID
                )
                mutationPreparationError = nil
            } catch {
                mutationDispatch = nil
                mutationPreparationError = error.localizedDescription
            }
        } else {
            mutationDispatch = nil
            mutationPreparationError = nil
        }

        commandTask?.cancel()
        let executionID = UUID()
        activeCommandExecutionID = executionID
        commandTask = Task.detached(priority: .userInitiated) {
            let outcome: TerminalCommandExecutionOutcome

            if isMutating, let mutationDispatch {
                do {
                    let receipt = try await mutationDispatch.coordinator
                        .performTerminal(
                            context: mutationDispatch.context,
                            operation: TerminalCanonicalMutationOperation
                                .runCommand(RunCommandArguments(command: cmd))
                        )
                    outcome = TerminalCommandExecutionOutcome(
                        output: draft.completedMutationSummary,
                        isError: false,
                        mutationDurablyCompleted: true,
                        mutationMayHaveApplied: false,
                        mutationOperationID: receipt.operationID
                    )
                } catch is CancellationError {
                    await MainActor.run {
                        guard activeCommandExecutionID == executionID else {
                            return
                        }
                        activeCommandExecutionID = nil
                        isExecuting = false
                        commandTask = nil
                    }
                    return
                } catch let policyError as AgentPolicyMutationServiceError
                    where policyError == .cancelled
                {
                    await MainActor.run {
                        guard activeCommandExecutionID == executionID else {
                            return
                        }
                        activeCommandExecutionID = nil
                        isExecuting = false
                        commandTask = nil
                    }
                    return
                } catch let policyError as AgentPolicyMutationServiceError {
                    outcome = TerminalCommandExecutionOutcome(
                        output: policyError.localizedDescription,
                        isError: true,
                        mutationDurablyCompleted: false,
                        mutationMayHaveApplied: policyError.terminalEffectMayHaveApplied,
                        mutationOperationID: mutationDispatch.operationID
                    )
                } catch {
                    outcome = TerminalCommandExecutionOutcome(
                        output: error.localizedDescription,
                        isError: true,
                        mutationDurablyCompleted: false,
                        mutationMayHaveApplied: false,
                        mutationOperationID: mutationDispatch.operationID
                    )
                }
            } else if isMutating {
                outcome = TerminalCommandExecutionOutcome(
                    output: mutationPreparationError
                        ?? "NovaForge could not prepare this workspace command.",
                    isError: true,
                    mutationDurablyCompleted: false,
                    mutationMayHaveApplied: false,
                    mutationOperationID: mutationOperationID
                )
            } else {
                do {
                    outcome = TerminalCommandExecutionOutcome(
                        output: try CommandRunner(workspace: workspace).run(cmd),
                        isError: false,
                        mutationDurablyCompleted: false,
                        mutationMayHaveApplied: false,
                        mutationOperationID: nil
                    )
                } catch {
                    outcome = TerminalCommandExecutionOutcome(
                        output: error.localizedDescription,
                        isError: true,
                        mutationDurablyCompleted: false,
                        mutationMayHaveApplied: false,
                        mutationOperationID: nil
                    )
                }
            }

            let duration = Date().timeIntervalSince(startTime) * 1000.0
            let completedAt = Date()
            await MainActor.run {
                let ownsExecution = activeCommandExecutionID == executionID
                guard ownsExecution ||
                        outcome.mutationDurablyCompleted ||
                        outcome.mutationMayHaveApplied else { return }
                let record = TerminalCommandRecord(
                    project: project,
                    command: cmd,
                    output: outcome.output,
                    status: outcome.isError ? .failed : .completed,
                    workspaceName: workspace.workspaceName,
                    startedAt: startTime,
                    completedAt: completedAt,
                    durationMs: duration
                )
                let newLine = TerminalOutputLine(record: record)
                consoleLines.append(newLine)
                if consoleLines.count > Self.maxConsoleLineCount {
                    let overflow = consoleLines.count - Self.maxConsoleLineCount
                    let removedIDs = consoleLines.prefix(overflow).map(\.id)
                    consoleLines.removeFirst(overflow)
                    expandedLineIDs.subtract(removedIDs)
                }
                commandHistory = TerminalConsoleState.commandHistory(from: consoleLines, maxCount: Self.maxHistoryCount)
                updateFilteredConsoleLines()
                modelContext.insert(record)

                var eventMetadata = [
                    "command": cmd,
                    "workspace": workspace.workspaceName
                ]
                if let operationID = outcome.mutationOperationID {
                    eventMetadata["workspaceMutationID"] = operationID.uuidString
                }
                if outcome.mutationDurablyCompleted {
                    eventMetadata["mutationOutcome"] = "completed"
                } else if outcome.mutationMayHaveApplied {
                    eventMetadata["mutationOutcome"] = "may_have_applied"
                } else if isMutating {
                    eventMetadata["mutationOutcome"] = "not_applied"
                }

                let eventTitle: String
                let eventSeverity: ProjectEventSeverity
                if outcome.mutationMayHaveApplied {
                    eventTitle = "Terminal mutation needs inspection"
                    eventSeverity = .warning
                } else if outcome.isError {
                    eventTitle = "Terminal command failed"
                    eventSeverity = .failure
                } else {
                    eventTitle = "Terminal command completed"
                    eventSeverity = .success
                }
                ProjectEventRecorder.record(
                    project: project,
                    kind: .terminalCommand,
                    title: eventTitle,
                    detail: cmd,
                    severity: eventSeverity,
                    sourceType: .terminalCommand,
                    sourceID: record.id,
                    metadata: eventMetadata,
                    context: modelContext
                )
                if outcome.mutationDurablyCompleted {
                    ProjectEventRecorder.recordFileChange(
                        project: project,
                        action: "Ran terminal mutation",
                        path: cmd,
                        sourceTerminalCommandID: record.id,
                        context: modelContext
                    )
                    runtime.noteWorkspaceChanged()
                } else if outcome.mutationMayHaveApplied {
                    // A thrown effect or failed settlement is never ordinary
                    // success, but cached file summaries must assume bytes may
                    // have changed until the operator inspects the workspace.
                    runtime.noteWorkspaceChanged()
                }
                do {
                    try modelContext.save()
                } catch {
                    modelContext.rollback()
                    terminalSaveError = "NovaForge could not save this terminal result or timeline event. The output remains visible only in this Terminal session. \(error.localizedDescription)"
                    UINotificationFeedbackGenerator().notificationOccurred(.error)
                }
                if ownsExecution {
                    activeCommandExecutionID = nil
                    isExecuting = false
                    commandTask = nil
                }

                if !ownsExecution {
                    return
                } else if outcome.isError {
                    let errorImpact = UINotificationFeedbackGenerator()
                    errorImpact.notificationOccurred(.error)
                } else {
                    let successImpact = UIImpactFeedbackGenerator(style: .medium)
                    successImpact.impactOccurred()
                }
            }
        }
    }

    private static func terminalMutationIdempotencyKey(
        operationID: UUID
    ) -> String {
        "terminal.run-command.v1:\(operationID.uuidString.lowercased())"
    }
    
    private func clearConsole() {
        consoleLines.removeAll()
        filteredConsoleLines.removeAll()
        expandedLineIDs.removeAll()
        focusedLineID = nil
        pendingScrollLineID = nil
        searchQuery = ""
        debouncedSearchQuery = ""
    }

    private func syncConsoleWithProjectRecords() {
        let recordLines = projectRecordLines()
        let syncedLines = TerminalConsoleState.mergeLines(
            current: consoleLines,
            recordLines: recordLines,
            maxCount: Self.maxConsoleLineCount
        )
        applyConsoleLines(syncedLines)
        applyInitialFocusIfNeeded()
    }

    private func replaceConsoleWithProjectRecords() {
        applyConsoleLines(projectRecordLines())
        applyInitialFocusIfNeeded()
    }

    private func projectRecordLines() -> [TerminalOutputLine] {
        let signpostID = AgentPerformance.begin("Terminal Proof Surface Load")
        defer {
            AgentPerformance.end("Terminal Proof Surface Load", id: signpostID)
        }
        let projectID = project.id
        return terminalRecords
            .filter { $0.project?.id == projectID }
            .sorted { lhs, rhs in
                if lhs.completedAt != rhs.completedAt { return lhs.completedAt < rhs.completedAt }
                return lhs.id.uuidString < rhs.id.uuidString
            }
            .suffix(Self.maxConsoleLineCount)
            .map(TerminalOutputLine.init(record:))
    }

    private func applyConsoleLines(_ lines: [TerminalOutputLine]) {
        consoleLines = lines
        commandHistory = TerminalConsoleState.commandHistory(from: lines, maxCount: Self.maxHistoryCount)
        updateFilteredConsoleLines()
    }

    private func updateFilteredConsoleLines() {
        AgentPerformance.event("Terminal Filter Update")
        filteredConsoleLines = TerminalConsoleState.filteredLines(
            from: consoleLines,
            query: debouncedSearchQuery,
            outputLimit: Self.searchableOutputLimit
        )
        let existingIDs = Set(consoleLines.map(\.id))
        let visibleIDs = Set(filteredConsoleLines.map(\.id))
        expandedLineIDs = expandedLineIDs.intersection(existingIDs)
        if let focusedLineID, !visibleIDs.contains(focusedLineID) {
            self.focusedLineID = nil
        }
    }

    private func applyInitialFocusIfNeeded() {
        guard let initialFocus, appliedFocusID != initialFocus.id else { return }
        guard consoleLines.contains(where: { $0.id == initialFocus.id }) else { return }
        appliedFocusID = initialFocus.id
        focusedLineID = initialFocus.id
        expandedLineIDs.insert(initialFocus.id)
        isSearchExpanded = true
        searchQuery = initialFocus.query
        debouncedSearchQuery = initialFocus.query
        updateFilteredConsoleLines()
        pendingScrollLineID = initialFocus.id
    }

    private func updateMatchingCommands() {
        let command = inputCommand.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        matchingCommands = TerminalCommandCatalog.autocompleteCommands
            .map(\.command)
            .filter { suggestion in
                let normalized = suggestion.lowercased()
                return !command.isEmpty && normalized.hasPrefix(command) && normalized != command
            }
    }

    private func toggleOutputDetails(_ id: UUID) {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        withAnimation(.smooth(duration: 0.18)) {
            if expandedLineIDs.contains(id) {
                expandedLineIDs.remove(id)
            } else {
                expandedLineIDs.insert(id)
            }
        }
    }

    private func copyOutput(_ line: TerminalOutputLine) {
        UIPasteboard.general.string = line.output
        copiedOutputLineID = line.id
        copyFeedbackTask?.cancel()
        copyFeedbackTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.4))
            guard !Task.isCancelled else { return }
            if copiedOutputLineID == line.id {
                copiedOutputLineID = nil
            }
            copyFeedbackTask = nil
        }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    private func seedTerminalStressIfNeeded() {
        #if DEBUG
        guard ProcessInfo.processInfo.arguments.contains("--stress-terminal"), !hasSeededTerminalStress else {
            return
        }

        hasSeededTerminalStress = true
        let output = (1...140)
            .map { "line \($0): generated terminal fixture output for progressive disclosure and scroll performance." }
            .joined(separator: "\n")
        let line = TerminalOutputLine(
            command: "cat Generated/very-long.log",
            output: output,
            isError: false,
            durationMs: 32
        )
        consoleLines = [line]
        commandHistory = [line.command]
        #endif
    }

    #if DEBUG
    private func seedTerminalSafetyDemoIfNeeded() {
        guard ProcessInfo.processInfo.arguments.contains("--terminal-safety-demo"), inputCommand.isEmpty else {
            return
        }
        inputCommand = "rm README.md"
    }

    private func seedTerminalUnsupportedDemoIfNeeded() {
        guard ProcessInfo.processInfo.arguments.contains("--terminal-unsupported-demo"), inputCommand.isEmpty else {
            return
        }
        inputCommand = "curl https://example.com"
    }
    #endif
    
    private var historySheet: some View {
        ZStack {
            AgentBackground()
            VStack(alignment: .leading, spacing: 18) {
                HeaderView(title: "History", subtitle: "Previously executed commands", symbol: "clock")
                
                if commandHistory.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "clock.badge.exclamationmark")
                            .font(.largeTitle)
                            .foregroundStyle(AgentPalette.secondaryText)
                        Text("No commands run yet")
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(AgentPalette.secondaryText)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 8) {
                            ForEach(Array(commandHistory.enumerated()), id: \.offset) { _, cmd in
                                Button {
                                    inputCommand = cmd
                                    showingHistorySheet = false
                                } label: {
                                    HStack {
                                        Text(cmd)
                                            .font(.system(.subheadline, design: .monospaced, weight: .bold))
                                            .foregroundStyle(AgentPalette.ink)
                                        Spacer()
                                        Image(systemName: "arrow.up.left.circle")
                                            .foregroundStyle(AgentPalette.cyan)
                                    }
                                    .padding(12)
                                    .agentRowSurface(radius: 14, tint: AgentPalette.cyan)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                
                Button {
                    showingHistorySheet = false
                } label: {
                    Text("Close")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            .padding()
        }
    }
}

/// Classic block cursor idling on the empty prompt line.
private struct TerminalBlinkingCursor: View {
    @State private var visible = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        RoundedRectangle(cornerRadius: 1.5, style: .continuous)
            .fill(AgentPalette.terminalPrompt)
            .frame(width: 9, height: 17)
            .opacity(visible ? 0.95 : 0.12)
            .onAppear {
                guard AgentPerformance.allowsDecorativeMotion, !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 0.55).repeatForever(autoreverses: true)) {
                    visible = false
                }
            }
            .accessibilityHidden(true)
    }
}

struct ConsoleLogLineView: View {
    let line: TerminalOutputLine
    let fontSize: CGFloat
    let isExpanded: Bool

    private var renderedLines: [String] {
        isExpanded ? line.detailOutputLines : line.previewOutputLines
    }

    private var hiddenLineCount: Int {
        isExpanded ? line.hiddenOutputLineCount : line.collapsedHiddenLineCount
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(renderedLines.enumerated()), id: \.offset) { index, logLine in
                HStack(alignment: .top, spacing: 8) {
                    Text(String(format: "%02d", index + 1))
                        .font(.system(size: max(8, fontSize - 2), weight: .bold, design: .monospaced))
                        .foregroundStyle(AgentPalette.terminalOutput.opacity(0.38))
                        .frame(width: 24, alignment: .trailing)

                    Text(logLine.isEmpty ? " " : logLine)
                        .font(.system(size: fontSize, weight: outputWeight(for: logLine), design: .monospaced))
                        .foregroundStyle(outputColor(for: logLine))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            if hiddenLineCount > 0 {
                Text(summaryText)
                    .font(.system(size: max(9, fontSize - 1), weight: .semibold, design: AgentPalette.interfaceFontDesign))
                    .foregroundStyle(AgentPalette.secondaryText)
                    .padding(.top, 6)
            }
        }
    }

    private func outputWeight(for line: String) -> Font.Weight {
        if line.localizedCaseInsensitiveContains("error") || line.localizedCaseInsensitiveContains("failed") {
            return .bold
        }
        if line.localizedCaseInsensitiveContains("warning") {
            return .medium
        }
        return .regular
    }

    private func outputColor(for line: String) -> Color {
        if line.localizedCaseInsensitiveContains("error") || line.localizedCaseInsensitiveContains("failed") {
            return AgentPalette.terminalError
        }
        if line.localizedCaseInsensitiveContains("warning") {
            return AgentPalette.terminalWarning
        }
        return AgentPalette.terminalOutput
    }

    private var summaryText: String {
        if isExpanded {
            return "\(hiddenLineCount) more line\(hiddenLineCount == 1 ? "" : "s") hidden for smooth scrolling. Use Copy Output for the full log."
        }
        return "\(hiddenLineCount) more line\(hiddenLineCount == 1 ? "" : "s") hidden. Open details only when needed."
    }
}

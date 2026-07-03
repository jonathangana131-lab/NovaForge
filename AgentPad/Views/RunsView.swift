import Foundation
import SwiftData
import SwiftUI

struct RunsView: View {
    @Environment(\.modelContext) var modelContext
    var runtime: AgentRuntime
    var project: Project
    let openArtifactLandscapeFullScreen: (WorkspaceArtifact) -> Void
    let openTerminalRecord: (UUID, String, String) -> Void
    let openProject: () -> Void
    let approvePendingTool: () -> Void
    let rejectPendingTool: () -> Void
    let openChat: () -> Void
    @Query var runs: [ToolRun]
    @Query var terminalRecords: [TerminalCommandRecord]
    @SceneStorage("RunsView.filterType") var restoredFilterTypeRawValue = FilterType.all.rawValue
    @SceneStorage("RunsView.expandedRunID") var expandedRunIDString = ""

    @State var searchText = ""
    @State var debouncedSearchText = ""
    @State var previewArtifact: WorkspaceArtifact?
    @State var replayTarget: RunReplayTarget?

    @State var cachedStats = RunStats()
    @State var cachedFilteredRuns: [RunRowData] = []
    @State var cachedMatchingRunCount = 0
    @State var cachedSparklineDurations: [Double] = []
    @State var runDeleteError: String?
    @FocusState var searchFocused: Bool

    static let fetchedRunLimit = 500
    static let visibleRunLimit = 80
    static let fetchedTerminalRecordLimit = 500
    static let searchableArgumentsLimit = 2_000
    static let searchableOutputLimit = 600
    let tabBarClearance: CGFloat = BottomDockMetrics.scrollClearance

    var activeFilterType: FilterType {
        FilterType(rawValue: restoredFilterTypeRawValue) ?? .all
    }

    var missionContract: MissionOSContract {
        ProjectMissionSummarizer.summarize(project: project, context: modelContext).missionContract
    }

    var artifactIterationPrompt: String {
        ProjectMissionSummarizer.summarize(project: project, context: modelContext).workflowSpine.iterationPrompt
    }

    init(
        runtime: AgentRuntime,
        project: Project,
        openArtifactLandscapeFullScreen: @escaping (WorkspaceArtifact) -> Void,
        openTerminalRecord: @escaping (UUID, String, String) -> Void,
        openProject: @escaping () -> Void,
        approvePendingTool: @escaping () -> Void,
        rejectPendingTool: @escaping () -> Void,
        openChat: @escaping () -> Void
    ) {
        self.runtime = runtime
        self.project = project
        self.openArtifactLandscapeFullScreen = openArtifactLandscapeFullScreen
        self.openTerminalRecord = openTerminalRecord
        self.openProject = openProject
        self.approvePendingTool = approvePendingTool
        self.rejectPendingTool = rejectPendingTool
        self.openChat = openChat

        var descriptor = FetchDescriptor<ToolRun>(
            sortBy: [SortDescriptor(\ToolRun.createdAt, order: .reverse)]
        )
        descriptor.fetchLimit = Self.fetchedRunLimit
        _runs = Query(descriptor)

        var terminalDescriptor = FetchDescriptor<TerminalCommandRecord>(
            sortBy: [SortDescriptor(\TerminalCommandRecord.completedAt, order: .reverse)]
        )
        terminalDescriptor.fetchLimit = Self.fetchedTerminalRecordLimit
        _terminalRecords = Query(terminalDescriptor)
    }

    enum FilterType: String, CaseIterable, Identifiable {
        case all = "All"
        case writes = "Writes"
        case failures = "Failures"
        
        var id: String { rawValue }
    }

    struct RunRowData: Identifiable, Equatable {
        let id: UUID
        let name: String
        let status: ToolRunStatus
        let createdAt: Date
        let createdTimeText: String
        let isMutating: Bool
        let argumentsJSON: String
        let output: String
        let durationMs: Double
        let durationText: String?
        let isFast: Bool
        let isHeavy: Bool
        let displayName: String
        let argumentSummary: String?
        let argumentsByteText: String
        let argumentsPreview: String
        let outputByteText: String
        let outputPreview: String
        let outputPreviewIsTruncated: Bool
        let elapsedText: String
        let phaseTitle: String
        let phaseDetail: String
        let evidenceSummary: String
        let logSummary: String
        let nextActionTitle: String
        let nextActionDetail: String
        let timelinePhases: [RunTimelinePhase]
        let artifact: WorkspaceArtifact?
        let terminalProof: TerminalProofData?

        init(run: ToolRun, terminalRecord: TerminalCommandRecord?) {
            id = run.id
            name = run.name
            status = run.status
            createdAt = run.createdAt
            createdTimeText = DateFormatter.localizedString(from: run.createdAt, dateStyle: .none, timeStyle: .short)
            isMutating = run.isMutating
            argumentsJSON = run.argumentsJSON
            output = run.output
            if let completed = run.completedAt {
                durationMs = completed.timeIntervalSince(run.createdAt) * 1000.0
            } else {
                durationMs = 0
            }
            durationText = durationMs > 0 ? String(format: "%.0fms", durationMs) : nil
            isFast = durationMs > 0 && durationMs < 150
            isHeavy = durationMs > 1500
            displayName = Self.displayName(for: run.name)
            argumentSummary = RunArgumentSummary.make(from: run.argumentsJSON)
            argumentsByteText = Self.byteText(for: run.argumentsJSON)
            let argumentSnapshot = Self.makePreview(
                from: run.argumentsJSON,
                maxCharacters: 1_600,
                maxLines: 18,
                truncationNotice: "arguments truncated for smooth rendering. Use Copy Args for the full payload."
            )
            argumentsPreview = argumentSnapshot.text
            outputByteText = Self.byteText(for: run.output)
            let outputSnapshot = Self.makePreview(
                from: run.output,
                maxCharacters: 1_200,
                maxLines: 14,
                truncationNotice: "output preview capped for smooth scrolling. Use Copy Output for the full log."
            )
            outputPreview = outputSnapshot.text
            outputPreviewIsTruncated = outputSnapshot.isTruncated
            let resolvedArtifact = WorkspaceArtifact.fromToolOutput(run.output)
            let resolvedTerminalProof: TerminalProofData?
            if let terminalRecord {
                resolvedTerminalProof = TerminalProofData(record: terminalRecord)
            } else if run.name == "run_command" {
                resolvedTerminalProof = TerminalProofData(run: run)
            } else {
                resolvedTerminalProof = nil
            }
            artifact = resolvedArtifact
            terminalProof = resolvedTerminalProof
            elapsedText = Self.elapsedText(for: run)
            phaseTitle = Self.phaseTitle(for: run, artifact: resolvedArtifact, terminalProof: resolvedTerminalProof)
            phaseDetail = Self.phaseDetail(for: run, argumentSummary: argumentSummary, artifact: resolvedArtifact, terminalProof: resolvedTerminalProof)
            evidenceSummary = Self.evidenceSummary(for: run, artifact: resolvedArtifact, terminalProof: resolvedTerminalProof)
            logSummary = "\(argumentsByteText) args · \(outputByteText) output"
            nextActionTitle = Self.nextActionTitle(for: run, artifact: resolvedArtifact, terminalProof: resolvedTerminalProof)
            nextActionDetail = Self.nextActionDetail(for: run, artifact: resolvedArtifact, terminalProof: resolvedTerminalProof)
            timelinePhases = Self.timelinePhases(for: run, artifact: resolvedArtifact, terminalProof: resolvedTerminalProof)
        }

        private static func displayName(for name: String) -> String {
            switch name {
            case "read_file": return "Read file"
            case "read_file_range": return "Read range"
            case "tail_file": return "Tailed file"
            case "write_file": return "Wrote file"
            case "append_file": return "Appended file"
            case "replace_text": return "Replaced text"
            case "patch_file": return "Edited file"
            case "list_directory": return "Listed files"
            case "list_tree": return "Listed tree"
            case "workspace_summary": return "Summarized workspace"
            case "file_info": return "Inspected file"
            case "search_files": return "Searched files"
            case "search_text": return "Searched text"
            case "diff_files": return "Diffed files"
            case "validate_json": return "Validated JSON"
            case "validate_html_file": return "Validated HTML"
            case "extract_outline": return "Extracted outline"
            case "terminal", "run_command": return "Ran command"
            default:
                return name
                    .replacingOccurrences(of: "_", with: " ")
                    .split(separator: " ")
                    .map { word in
                        word.count <= 2 ? String(word) : word.prefix(1).uppercased() + word.dropFirst()
                    }
                    .joined(separator: " ")
            }
        }

        fileprivate static func byteText(for text: String) -> String {
            let count = text.data(using: .utf8)?.count ?? text.utf8.count
            return ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: .file)
        }

        fileprivate static func makePreview(
            from text: String,
            maxCharacters: Int,
            maxLines: Int,
            truncationNotice: String
        ) -> (text: String, isTruncated: Bool) {
            guard !text.isEmpty else { return ("", false) }

            var collected: [String] = []
            var lineCount = 0
            var characterCount = 0
            var didStopEarly = false
            text.enumerateLines { line, stop in
                lineCount += 1
                let separatorCount = collected.isEmpty ? 0 : 1
                let remainingCharacters = maxCharacters - characterCount - separatorCount
                if collected.count >= maxLines || remainingCharacters <= 0 {
                    didStopEarly = true
                    stop = true
                    return
                }

                if line.count > remainingCharacters {
                    collected.append(String(line.prefix(remainingCharacters)))
                    characterCount = maxCharacters
                    didStopEarly = true
                    stop = true
                    return
                }

                collected.append(line)
                characterCount += line.count + separatorCount
            }

            if collected.isEmpty {
                let prefix = String(text.prefix(maxCharacters))
                let truncated = text.count > prefix.count
                return (truncated ? prefix + "\n\n… \(truncationNotice)" : prefix, truncated)
            }

            let consumedWholeText = characterCount >= text.count || (!didStopEarly && lineCount <= maxLines)
            let isTruncated = didStopEarly || !consumedWholeText
            let preview = collected.joined(separator: "\n")
            return (isTruncated ? preview + "\n\n… \(truncationNotice)" : preview, isTruncated)
        }

        private static func elapsedText(for run: ToolRun) -> String {
            let end = run.completedAt ?? Date()
            let seconds = max(0, end.timeIntervalSince(run.createdAt))
            if seconds < 1 {
                return String(format: "%.0fms", seconds * 1000.0)
            }
            if seconds < 60 {
                return String(format: "%.1fs", seconds)
            }
            let minutes = Int(seconds / 60)
            let remainder = Int(seconds) % 60
            return remainder == 0 ? "\(minutes)m" : "\(minutes)m \(remainder)s"
        }

        private static func phaseTitle(
            for run: ToolRun,
            artifact: WorkspaceArtifact?,
            terminalProof: TerminalProofData?
        ) -> String {
            switch run.status {
            case .pendingApproval:
                return "Approval gate"
            case .approved:
                return "Approved and running"
            case .rejected:
                return "Approval rejected"
            case .failed:
                return "Failed evidence"
            case .completed:
                if artifact != nil { return "Proof artifact ready" }
                if terminalProof != nil { return "Terminal proof captured" }
                if run.isMutating { return "Workspace changed" }
                return "Inspection complete"
            }
        }

        private static func phaseDetail(
            for run: ToolRun,
            argumentSummary: String?,
            artifact: WorkspaceArtifact?,
            terminalProof: TerminalProofData?
        ) -> String {
            if let artifact { return artifact.path }
            if let terminalProof { return terminalProof.command }
            if let argumentSummary { return argumentSummary }
            if !run.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return "Output captured for \(displayName(for: run.name))."
            }
            return displayName(for: run.name)
        }

        private static func evidenceSummary(
            for run: ToolRun,
            artifact: WorkspaceArtifact?,
            terminalProof: TerminalProofData?
        ) -> String {
            var parts: [String] = []
            if artifact != nil { parts.append("artifact") }
            if terminalProof != nil { parts.append("terminal") }
            if run.isMutating { parts.append("write") }
            if !run.output.isEmpty { parts.append("output") }
            if parts.isEmpty { return "arguments only" }
            return parts.joined(separator: " + ")
        }

        private static func nextActionTitle(
            for run: ToolRun,
            artifact: WorkspaceArtifact?,
            terminalProof: TerminalProofData?
        ) -> String {
            switch run.status {
            case .pendingApproval:
                return "Decide approval"
            case .approved:
                return "Watch result"
            case .rejected:
                return "Revise request"
            case .failed:
                return "Recover"
            case .completed:
                if artifact != nil { return "Inspect proof" }
                if terminalProof != nil { return "Review log" }
                if run.isMutating { return "Verify changes" }
                return "Use as context"
            }
        }

        private static func nextActionDetail(
            for run: ToolRun,
            artifact: WorkspaceArtifact?,
            terminalProof: TerminalProofData?
        ) -> String {
            switch run.status {
            case .pendingApproval:
                return "Inspect the arguments, then approve or reject before the tool mutates anything."
            case .approved:
                return "The request was approved; wait for a terminal result, proof, or failure receipt."
            case .rejected:
                return "Open ProjectOS or Chat, adjust the request, and retry only after the risk is clear."
            case .failed:
                return "Use the captured output as recovery context, then rerun the smallest relevant check."
            case .completed:
                if artifact != nil { return "Open the artifact, inspect it, and continue from the proof result." }
                if terminalProof != nil { return "Review the linked terminal log before trusting the result." }
                if run.isMutating { return "Verify the changed files and capture proof." }
                return "Keep this run as context for the next project step."
            }
        }

        private static func timelinePhases(
            for run: ToolRun,
            artifact: WorkspaceArtifact?,
            terminalProof: TerminalProofData?
        ) -> [RunTimelinePhase] {
            var phases: [RunTimelinePhase] = [
                RunTimelinePhase(
                    id: "queued",
                    title: "Queued",
                    detail: displayName(for: run.name),
                    status: .done,
                    symbol: run.isMutating ? "pencil.and.outline" : "eye",
                    timestampText: DateFormatter.localizedString(from: run.createdAt, dateStyle: .none, timeStyle: .short)
                )
            ]

            if run.requiresApproval || run.status == .pendingApproval || run.status == .approved || run.status == .rejected {
                phases.append(
                    RunTimelinePhase(
                        id: "approval",
                        title: "Approval",
                        detail: run.status == .pendingApproval ? "Waiting for a decision" : run.status.displayTitle,
                        status: run.status == .pendingApproval ? .current : (run.status == .rejected ? .failed : .done),
                        symbol: "checkmark.shield.fill",
                        timestampText: run.status == .pendingApproval ? "Now" : run.completedAt.map { DateFormatter.localizedString(from: $0, dateStyle: .none, timeStyle: .short) } ?? ""
                    )
                )
            }

            phases.append(
                RunTimelinePhase(
                    id: "execution",
                    title: run.status == .failed ? "Failed" : "Executed",
                    detail: phaseDetail(for: run, argumentSummary: RunArgumentSummary.make(from: run.argumentsJSON), artifact: artifact, terminalProof: terminalProof),
                    status: executionPhaseStatus(for: run.status),
                    symbol: run.name == "run_command" ? "terminal.fill" : "wrench.and.screwdriver.fill",
                    timestampText: run.completedAt.map { DateFormatter.localizedString(from: $0, dateStyle: .none, timeStyle: .short) } ?? (run.status == .approved ? "Now" : "")
                )
            )

            if artifact != nil || terminalProof != nil || !run.output.isEmpty {
                phases.append(
                    RunTimelinePhase(
                        id: "evidence",
                        title: "Evidence",
                        detail: evidenceSummary(for: run, artifact: artifact, terminalProof: terminalProof),
                        status: run.status == .failed || run.status == .rejected ? .failed : .done,
                        symbol: artifact != nil ? "shippingbox.fill" : "checkmark.seal.fill",
                        timestampText: run.completedAt.map { DateFormatter.localizedString(from: $0, dateStyle: .none, timeStyle: .short) } ?? ""
                    )
                )
            }

            return phases
        }

        private static func executionPhaseStatus(for status: ToolRunStatus) -> RunTimelinePhase.Status {
            switch status {
            case .pendingApproval:
                return .pending
            case .approved:
                return .current
            case .rejected, .failed:
                return .failed
            case .completed:
                return .done
            }
        }
    }

    struct RunTimelinePhase: Identifiable, Equatable {
        enum Status: Equatable {
            case pending
            case current
            case done
            case failed
        }

        let id: String
        let title: String
        let detail: String
        let status: Status
        let symbol: String
        let timestampText: String
    }

    struct TerminalProofData: Identifiable, Equatable {
        let id: UUID
        let command: String
        let output: String
        let outputPreview: String
        let outputByteText: String
        let outputLineCountText: String
        let status: TerminalCommandStatus
        let durationText: String
        let completedTimeText: String
        let sourceText: String
        let canOpenTerminalRecord: Bool

        init(record: TerminalCommandRecord) {
            id = record.id
            command = record.command
            output = record.output
            outputByteText = RunRowData.byteText(for: record.output)
            let preview = RunRowData.makePreview(
                from: record.output,
                maxCharacters: 700,
                maxLines: 8,
                truncationNotice: "terminal output preview capped. Copy proof output keeps the full linked record."
            )
            outputPreview = preview.text
            outputLineCountText = Self.lineCountText(for: record.output)
            status = record.status
            durationText = String(format: "%.0fms", record.durationMs)
            completedTimeText = DateFormatter.localizedString(from: record.completedAt, dateStyle: .none, timeStyle: .short)
            sourceText = "Linked record"
            canOpenTerminalRecord = true
        }

        init(run: ToolRun) {
            id = run.id
            command = Self.command(from: run.argumentsJSON)
            output = run.output
            outputByteText = RunRowData.byteText(for: run.output)
            let preview = RunRowData.makePreview(
                from: run.output,
                maxCharacters: 700,
                maxLines: 8,
                truncationNotice: "terminal output preview capped. Copy proof output keeps the full run output."
            )
            outputPreview = preview.text
            outputLineCountText = Self.lineCountText(for: run.output)
            status = (run.status == .failed || run.status == .rejected) ? .failed : .completed
            if let completedAt = run.completedAt {
                durationText = String(format: "%.0fms", completedAt.timeIntervalSince(run.createdAt) * 1000.0)
                completedTimeText = DateFormatter.localizedString(from: completedAt, dateStyle: .none, timeStyle: .short)
            } else {
                durationText = "0ms"
                completedTimeText = DateFormatter.localizedString(from: run.createdAt, dateStyle: .none, timeStyle: .short)
            }
            sourceText = "Run output"
            canOpenTerminalRecord = false
        }

        var statusText: String {
            status == .completed ? "OK" : "FAIL"
        }

        var terminalFocusQuery: String {
            let meaningfulOutputLine = outputPreview
                .split(separator: "\n", omittingEmptySubsequences: true)
                .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { line in
                    line.count >= 3 && !line.hasPrefix("…")
                } ?? ""
            return meaningfulOutputLine.isEmpty ? command : meaningfulOutputLine
        }

        private static func lineCountText(for output: String) -> String {
            guard !output.isEmpty else { return "0 lines" }
            var count = 0
            output.enumerateLines { _, _ in
                count += 1
            }
            let normalizedCount = max(count, 1)
            return "\(normalizedCount) line\(normalizedCount == 1 ? "" : "s")"
        }

        private static func command(from argumentsJSON: String) -> String {
            guard let data = argumentsJSON.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let command = object["command"] as? String else {
                return "run_command"
            }
            let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "run_command" : trimmed
        }
    }

    struct RunStats {
        var total = 0
        var mutations = 0
        var failures = 0
        var pending = 0
        var completed = 0
        var finished = 0
        var totalDurationMs = 0.0

        var averageDurationText: String {
            // No data reads as an em dash, not a fake measurement.
            guard finished > 0 else { return "\u{2014}" }
            let avg = totalDurationMs / Double(finished)
            return avg < 1000 ? String(format: "%.0fms", avg) : String(format: "%.1fs", avg / 1000.0)
        }

        var successRateText: String {
            // "100%" of zero runs is a lie; show an em dash until data exists.
            guard finished > 0 else { return "\u{2014}" }
            let rate = Double(completed) / Double(finished) * 100.0
            return String(format: "%.0f%%", rate)
        }

        var successRateExplanation: String {
            guard finished > 0 else { return "No finished runs yet; proof will appear after the first completed or failed run." }
            return "\(completed) completed of \(finished) finished runs. Failed and rejected rows are retained as evidence."
        }
    }

    func updateCachedData() {
        AgentPerformance.event("Runs Filter Update")
        let signpostID = AgentPerformance.begin("Runs Cache Update")
        defer {
            AgentPerformance.end("Runs Cache Update", id: signpostID)
        }
        let activeProjectID = project.id
        let projectRuns = runs.filter { $0.project?.id == activeProjectID }
        var stats = RunStats()
        stats.total = projectRuns.count
        for run in projectRuns {
            if run.isMutating { stats.mutations += 1 }
            switch run.status {
            case .completed:
                stats.completed += 1
                stats.finished += 1
            case .failed, .rejected:
                stats.failures += 1
                stats.finished += 1
            case .pendingApproval, .approved:
                stats.pending += 1
            }
            if let completedAt = run.completedAt {
                stats.totalDurationMs += completedAt.timeIntervalSince(run.createdAt) * 1000.0
            }
        }
        self.cachedStats = stats
        self.cachedSparklineDurations = projectRuns.prefix(10).map { run in
            guard let completedAt = run.completedAt else { return 0 }
            return completedAt.timeIntervalSince(run.createdAt) * 1000.0
        }

        let query = debouncedSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let matching = projectRuns.filter { matches($0, query: query) }
        let filtered: [ToolRun]
        switch activeFilterType {
        case .all:
            filtered = matching
        case .writes:
            filtered = matching.filter { $0.isMutating }
        case .failures:
            filtered = matching.filter { $0.status == .failed || $0.status == .rejected }
        }
        let linkedTerminalRecords = terminalRecordsBySourceRunID()
        self.cachedFilteredRuns = filtered.prefix(Self.visibleRunLimit).map { run in
            RunRowData(run: run, terminalRecord: linkedTerminalRecords[run.id.uuidString])
        }
        self.cachedMatchingRunCount = filtered.count
        AgentPerformance.value("Runs Project Rows", Double(projectRuns.count))
        AgentPerformance.value("Runs Filtered Rows", Double(filtered.count))
    }

    func terminalRecordsBySourceRunID() -> [String: TerminalCommandRecord] {
        var linkedRecords: [String: TerminalCommandRecord] = [:]
        for record in terminalRecords {
            guard let sourceID = record.sourceToolRunIDString else { continue }
            if linkedRecords[sourceID] == nil {
                linkedRecords[sourceID] = record
            }
        }
        return linkedRecords
    }

    func preview(_ artifact: WorkspaceArtifact) {
        AgentPerformance.event("Artifact Preview Open")
        ProjectEventRecorder.noteArtifactPreview(
            artifact,
            project: project,
            context: modelContext
        )
        try? modelContext.save()
        previewArtifact = artifact
    }

    func matches(_ run: ToolRun, query: String) -> Bool {
        guard !query.isEmpty else { return true }

        if run.name.localizedCaseInsensitiveContains(query) ||
            run.status.rawValue.localizedCaseInsensitiveContains(query) {
            return true
        }

        if Self.boundedContains(run.argumentsJSON, query: query, limit: Self.searchableArgumentsLimit) {
            return true
        }

        guard query.count >= 3 else { return false }
        return Self.boundedContains(run.output, query: query, limit: Self.searchableOutputLimit)
    }

    static func boundedContains(_ text: String, query: String, limit: Int) -> Bool {
        guard !text.isEmpty else { return false }
        let end = text.index(text.startIndex, offsetBy: min(limit, text.count))
        return text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive], range: text.startIndex..<end) != nil
    }

    @MainActor
    func revealRun(_ id: UUID, anchor: UnitPoint, proxy: ScrollViewProxy) {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(140))
            withAnimation(.smooth(duration: 0.24)) {
                proxy.scrollTo(id, anchor: anchor)
            }
        }
    }

    func expansionBinding(for row: RunRowData) -> Binding<Bool> {
        Binding(
            get: { expandedRunIDString == row.id.uuidString },
            set: { isExpanded in
                if isExpanded {
                    expandedRunIDString = row.id.uuidString
                } else if expandedRunIDString == row.id.uuidString {
                    expandedRunIDString = ""
                }
            }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { scrollProxy in
                ScrollView {
                    LazyVStack(spacing: 14) {
                        HStack(spacing: 12) {
                            HeaderView(title: "Runs", subtitle: "\(project.name) tools and approvals", symbol: "waveform.path.ecg", tint: AgentPalette.lilac)
                        }
                        .padding(.bottom, 4)

                        if runtime.shouldShowWorkspaceStatusStrip {
                            WorkspaceStatusStrip(runtime: runtime, openChat: openChat)
                                .transition(.move(edge: .top).combined(with: .opacity))
                        }

                        MissionOSStatusStrip(contract: missionContract, surfaceName: "Runs")
                            .equatable()
                            .transition(.move(edge: .top).combined(with: .opacity))

                        runsCommandFocusPanel
                        auditDashboard

                        if cachedFilteredRuns.isEmpty {
                            AgentCenteredStateView(
                                title: emptyRunsTitle,
                                detail: emptyRunsDetail,
                                symbol: emptyRunsSymbol,
                                tint: emptyRunsTint
                            )
                            .padding(.top, 4)
                        } else {
                            ForEach(cachedFilteredRuns) { row in
                                RunCard(
                                    row: row,
                                    expanded: expansionBinding(for: row),
                                    hasLivePendingApproval: runtime.pendingTool != nil,
                                    deleteRun: { deleteRun(id: row.id) },
                                    openArtifact: { artifact in
                                        preview(artifact)
                                    },
                                    openTerminalRecord: { id, command, query in
                                        openTerminalRecord(id, command, query)
                                    },
                                    openProject: openProject,
                                    approvePendingTool: approvePendingTool,
                                    rejectPendingTool: rejectPendingTool,
                                    dismissSearch: {
                                        searchFocused = false
                                    },
                                    revealCard: { anchor in
                                        revealRun(row.id, anchor: anchor, proxy: scrollProxy)
                                    },
                                    openReplay: {
                                        replayTarget = RunReplayTarget(
                                            id: row.id,
                                            name: row.displayName,
                                            status: row.status,
                                            windowStart: row.createdAt,
                                            windowEnd: row.createdAt.addingTimeInterval(max(1, row.durationMs / 1_000) + 1)
                                        )
                                    }
                                )
                                .id(row.id)
                            }
                            if hasOffscreenRuns {
                                Text(runs.count >= Self.fetchedRunLimit ? "Showing newest \(Self.visibleRunLimit) rows from a \(Self.fetchedRunLimit)-run fetched window." : "Older matching run rows are kept offscreen for smooth scrolling.")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(AgentPalette.tertiaryText)
                                    .frame(maxWidth: .infinity, alignment: .center)
                                    .padding(.vertical, 8)
                            }
                        }
                    }
                    .padding()
                }
                .scrollContentBackground(.hidden)
                .scrollDismissesKeyboard(.interactively)
                .agentDockEdgeFade()
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    BottomDockContentShield(height: tabBarClearance)
                }
            }
        }
        .sheet(item: $replayTarget) { target in
            RunReplaySheet(target: target)
                .presentationDetents([.fraction(0.72), .large])
                .presentationDragIndicator(.visible)
        }
        .fullScreenCover(item: $previewArtifact) { artifact in
            ArtifactPreviewSheet(
                artifact: artifact,
                workspace: runtime.workspace,
                openLandscapeFullScreen: openArtifactLandscapeFullScreen,
                iterationPrompt: artifactIterationPrompt,
                openChat: openChat
            )
        }
        .task(id: searchText) {
            let value = searchText
            try? await Task.sleep(for: .milliseconds(220))
            guard !Task.isCancelled else { return }
            debouncedSearchText = value
        }
        .onChange(of: runs, initial: true) {
            updateCachedData()
        }
        .onChange(of: terminalRecords.count) {
            updateCachedData()
        }
        .onChange(of: project.id) {
            updateCachedData()
        }
        .onChange(of: restoredFilterTypeRawValue) {
            updateCachedData()
        }
        .onChange(of: debouncedSearchText) {
            updateCachedData()
        }
        .alert(
            "Run Log Error",
            isPresented: Binding(
                get: { runDeleteError != nil },
                set: { if !$0 { runDeleteError = nil } }
            )
        ) {
            Button("OK", role: .cancel) { runDeleteError = nil }
        } message: {
            Text(runDeleteError ?? "NovaForge could not save that run log change.")
        }
    }

    func deleteRun(id: UUID) {
        var descriptor = FetchDescriptor<ToolRun>(predicate: #Predicate<ToolRun> { run in
            run.id == id
        })
        descriptor.fetchLimit = 1
        do {
            guard let run = try modelContext.fetch(descriptor).first else { return }
            let cleanup = try ProjectRunLogCleanup.detachDeletedRunProvenance(for: run, context: modelContext)
            ProjectEventRecorder.record(
                project: run.project ?? project,
                kind: .runLogDeleted,
                title: "Run log deleted",
                detail: run.name,
                severity: .info,
                sourceType: .system,
                metadata: [
                    "status": run.status.rawValue,
                    "runID": run.id.uuidString,
                    "detachedLinks": "\(cleanup.totalDetachedLinks)"
                ],
                context: modelContext
            )
            modelContext.delete(run)
            try modelContext.save()
            updateCachedData()
        } catch {
            modelContext.rollback()
            runDeleteError = "Could not delete this run log. \(error.localizedDescription)"
            UINotificationFeedbackGenerator().notificationOccurred(.error)
        }
    }

    var hasOffscreenRuns: Bool {
        cachedFilteredRuns.count < cachedMatchingRunCount ||
        (activeFilterType == .all && debouncedSearchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && runs.count >= Self.fetchedRunLimit)
    }

    var emptyRunsTitle: String {
        cachedStats.total == 0 ? "No runs yet" : "No matching run events"
    }

    var emptyRunsDetail: String {
        if cachedStats.total == 0 {
            return "Tool calls, approvals, and terminal proof will appear here after NovaForge acts."
        }
        return "Adjust the search or filter to review more run evidence."
    }

    var emptyRunsSymbol: String {
        cachedStats.total == 0 ? "waveform.path.ecg.rectangle" : "line.3.horizontal.decrease.circle"
    }

    var emptyRunsTint: Color {
        cachedStats.total == 0 ? AgentPalette.lilac : AgentPalette.secondaryText
    }

    var runsCommandFocusPanel: some View {
        let tint = runsFocusTint
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: runsFocusSymbol)
                    .font(.system(size: 14, weight: .black))
                    .foregroundStyle(tint)
                    .frame(width: 34, height: 34)
                    .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 11, style: .continuous))

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 7) {
                        Text("Run Command Center")
                            .font(.system(size: 8.5, weight: .black, design: AgentPalette.interfaceFontDesign))
                            .foregroundStyle(AgentPalette.tertiaryText)
                            .textCase(.uppercase)
                        Text(runsFocusBadge)
                            .font(.system(size: 8.5, weight: .black, design: AgentPalette.interfaceFontDesign))
                            .foregroundStyle(tint)
                            .lineLimit(1)
                            .padding(.horizontal, 7)
                            .frame(height: 19)
                            .background(tint.opacity(0.10), in: Capsule(style: .continuous))
                    }

                    Text(runsFocusTitle)
                        .font(.system(size: 15, weight: .black, design: AgentPalette.interfaceFontDesign))
                        .foregroundStyle(AgentPalette.ink)
                        .lineLimit(2)
                        .minimumScaleFactor(0.82)
                        .accessibilityIdentifier("runsFocusTitle")

                    Text(runsFocusDetail)
                        .font(.system(size: 10.5, weight: .semibold, design: AgentPalette.interfaceFontDesign))
                        .foregroundStyle(AgentPalette.secondaryText)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("runsFocusDetail")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(spacing: 7) {
                RunFocusMetric(value: "\(cachedStats.pending)", label: "Approvals", symbol: "checkmark.shield.fill", tint: cachedStats.pending > 0 ? AgentPalette.cyan : AgentPalette.tertiaryText)
                RunFocusMetric(value: "\(cachedStats.failures)", label: "Issues", symbol: "exclamationmark.triangle.fill", tint: cachedStats.failures > 0 ? AgentPalette.rose : AgentPalette.green)
                RunFocusMetric(value: "\(cachedStats.completed)", label: "Proof", symbol: "checkmark.seal.fill", tint: cachedStats.completed > 0 ? AgentPalette.green : AgentPalette.tertiaryText)
            }

            runsFocusActions
        }
        .padding(12)
        .background(
            LinearGradient(
                colors: [AgentPalette.surface, tint.opacity(0.10), AgentPalette.surfaceAlt.opacity(0.35)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 22, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(tint.opacity(0.18), lineWidth: 0.65)
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("runsCommandFocusPanel")
    }

    @ViewBuilder
    var runsFocusActions: some View {
        if runtime.pendingTool != nil {
            HStack(spacing: 8) {
                runsFocusButton(title: "Approve", symbol: "checkmark.shield.fill", tint: AgentPalette.green, action: approvePendingTool)
                runsFocusButton(title: "Reject", symbol: "xmark.shield.fill", tint: AgentPalette.rose, action: rejectPendingTool)
            }
            .accessibilityIdentifier("runsApprovalActions")
        } else if runtime.wasInterrupted || runtime.lastError != nil {
            HStack(spacing: 8) {
                runsFocusButton(title: runtime.wasInterrupted ? "Resume" : "Recover", symbol: "arrow.clockwise", tint: runsFocusTint, action: openProject)
                runsFocusButton(title: "Chat", symbol: "bubble.left.and.bubble.right.fill", tint: AgentPalette.cyan, action: openChat)
            }
        } else if runtime.isWorking {
            HStack(spacing: 8) {
                runsFocusButton(title: "ProjectOS", symbol: "scope", tint: AgentPalette.green, action: openProject)
                runsFocusButton(title: "Chat", symbol: "bubble.left.and.bubble.right.fill", tint: AgentPalette.cyan, action: openChat)
            }
        } else {
            HStack(spacing: 8) {
                runsFocusButton(title: "ProjectOS", symbol: "scope", tint: AgentPalette.lilac, action: openProject)
                runsFocusButton(title: "Chat", symbol: "bubble.left.and.bubble.right.fill", tint: AgentPalette.cyan, action: openChat)
            }
        }
    }

    func runsFocusButton(title: String, symbol: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            action()
        } label: {
            Label(title, systemImage: symbol)
                .font(.system(size: 10.5, weight: .black, design: AgentPalette.interfaceFontDesign))
                .lineLimit(1)
                .minimumScaleFactor(0.82)
                .frame(maxWidth: .infinity, minHeight: AgentDesign.minimumTouchTarget)
        }
        .buttonStyle(.plain)
        .foregroundStyle(AgentPalette.ink)
        .agentControlSurface(radius: 12, tint: tint.opacity(0.14), selected: true)
    }

    var runsFocusTitle: String {
        if let pendingTool = runtime.pendingTool {
            return "\(pendingTool.name) is waiting for approval"
        }
        if runtime.wasInterrupted { return "Paused run can be resumed" }
        if runtime.lastError != nil { return "Recovery is available" }
        if runtime.isWorking { return runtime.activeToolName.map { "Running \($0)" } ?? runtime.activityTitle }
        if cachedStats.failures > 0 { return "Review failed evidence before continuing" }
        if cachedStats.pending > 0 { return "Saved approvals need review" }
        if cachedStats.completed > 0 { return "Proof trail is ready" }
        return "Ready to capture the first run"
    }

    var runsFocusDetail: String {
        if runtime.pendingTool != nil || runtime.wasInterrupted || runtime.lastError != nil || runtime.isWorking {
            return runtime.activityDetail
        }
        if cachedStats.failures > 0 {
            return "\(cachedStats.failures) failed or rejected run\(cachedStats.failures == 1 ? "" : "s") remain in the audit trail with output and recovery context."
        }
        if cachedStats.pending > 0 {
            return "\(cachedStats.pending) approval request\(cachedStats.pending == 1 ? "" : "s") are logged. Open ProjectOS or Chat to continue safely."
        }
        if cachedStats.completed > 0 {
            return "\(cachedStats.completed) completed run\(cachedStats.completed == 1 ? "" : "s") with arguments, output, proof, and linked terminal records when available."
        }
        return "Tool calls, approvals, terminal proof, and changed artifacts will appear here as NovaForge works."
    }

    var runsFocusBadge: String {
        if runtime.pendingTool != nil { return "Approval" }
        if runtime.wasInterrupted { return "Resume" }
        if runtime.lastError != nil { return "Recover" }
        if runtime.isWorking { return "Live" }
        if cachedStats.failures > 0 { return "Issues" }
        if cachedStats.completed > 0 { return "Proof" }
        return "Idle"
    }

    var runsFocusSymbol: String {
        if runtime.pendingTool != nil { return "checkmark.shield.fill" }
        if runtime.wasInterrupted { return "pause.circle.fill" }
        if runtime.lastError != nil || cachedStats.failures > 0 { return "exclamationmark.triangle.fill" }
        if runtime.isWorking { return "waveform" }
        if cachedStats.completed > 0 { return "checkmark.seal.fill" }
        return "waveform.path.ecg"
    }

    var runsFocusTint: Color {
        if runtime.pendingTool != nil { return AgentPalette.cyan }
        if runtime.wasInterrupted { return AgentPalette.lilac }
        if runtime.lastError != nil || cachedStats.failures > 0 { return AgentPalette.rose }
        if runtime.isWorking || cachedStats.completed > 0 { return AgentPalette.green }
        return AgentPalette.lilac
    }

    var auditDashboard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 15, style: .continuous)
                        .fill(AgentPalette.lilac.opacity(0.14))
                        .frame(width: 42, height: 42)
                    Image(systemName: "chart.xyaxis.line")
                        .font(.system(size: 17, weight: .black))
                        .foregroundStyle(AgentPalette.lilac)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text("Run Audit")
                        .font(.system(size: 15, weight: .black, design: AgentPalette.interfaceFontDesign))
                        .foregroundStyle(AgentPalette.ink)
                    Text(auditSubtitle)
                        .font(.system(size: 10, weight: .bold, design: AgentPalette.interfaceFontDesign))
                        .foregroundStyle(AgentPalette.secondaryText)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)

                Text("\(cachedFilteredRuns.count) shown")
                    .font(.system(size: 9, weight: .black, design: AgentPalette.interfaceFontDesign))
                    .foregroundStyle(AgentPalette.lilac)
                    .padding(.horizontal, 8)
                    .frame(height: 24)
                    .agentControlSurface(radius: 9, tint: AgentPalette.lilac.opacity(0.12), selected: true)
            }

            HStack(spacing: 8) {
                AuditMetric(value: cachedStats.successRateText, label: "Done Rate", symbol: "checkmark.seal.fill", tint: AgentPalette.green)
                AuditMetric(value: cachedStats.averageDurationText, label: "Average", symbol: "timer", tint: AgentPalette.lilac)
                AuditMetric(value: "\(cachedStats.failures)", label: "Issues", symbol: "exclamationmark.triangle.fill", tint: cachedStats.failures > 0 ? AgentPalette.rose : AgentPalette.cyan)
            }

            Label(cachedStats.successRateExplanation, systemImage: "info.circle.fill")
                .font(.system(size: 9.5, weight: .bold, design: AgentPalette.interfaceFontDesign))
                .foregroundStyle(AgentPalette.secondaryText)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .agentRowSurface(radius: 11, tint: AgentPalette.green.opacity(0.04))
                .accessibilityIdentifier("runsSuccessRateExplanation")

            HStack(spacing: 8) {
                AuditMetric(value: "\(cachedStats.total)", label: "Logged", symbol: "list.bullet.rectangle.fill", tint: AgentPalette.cyan)
                AuditMetric(value: "\(cachedStats.mutations)", label: "Writes", symbol: "pencil.and.outline", tint: AgentPalette.storageAccent)
                AuditMetric(value: "\(cachedStats.pending)", label: "Pending", symbol: "shield.lefthalf.filled", tint: cachedStats.pending > 0 ? AgentPalette.lilac : AgentPalette.secondaryText)
            }

            HStack(spacing: 9) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(AgentPalette.secondaryText)
                TextField("Search tool, status, path, or command", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.subheadline.weight(.semibold))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                    .onSubmit {
                        searchFocused = false
                    }
                    .focused($searchFocused)
                    .accessibilityIdentifier("runsSearchField")
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                        searchFocused = false
                    } label: {
                        ZStack {
                            Color.clear
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(AgentPalette.tertiaryText)
                        }
                        .frame(width: AgentDesign.minimumTouchTarget + 2, height: AgentDesign.minimumTouchTarget + 2)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear run search")
                    .accessibilityIdentifier("runsSearchClearButton")
                }
            }
            .padding(.horizontal, 12)
            .frame(minHeight: AgentDesign.minimumTouchTarget)
            .agentControlSurface(radius: 15, tint: AgentPalette.lilac.opacity(0.10))

            if !runs.isEmpty {
                HStack(spacing: 7) {
                    Label("Newest first", systemImage: "waveform.path.ecg")
                        .font(.system(size: 9, weight: .black, design: AgentPalette.interfaceFontDesign))
                        .foregroundStyle(AgentPalette.lilac)
                        .textCase(.uppercase)
                    Spacer(minLength: 0)
                    Text("\(min(cachedSparklineDurations.count, 10)) recent durations tracked")
                        .font(.system(size: 8.5, weight: .bold, design: AgentPalette.interfaceFontDesign))
                        .foregroundStyle(AgentPalette.tertiaryText)
                        .lineLimit(1)
                        .minimumScaleFactor(0.78)
                }
                .padding(.horizontal, 10)
                .frame(height: 32)
                .agentRowSurface(radius: 11, tint: AgentPalette.lilac.opacity(0.04))
            }

            HStack {
                filterSelector
                Spacer(minLength: 0)
            }
        }
        .padding(12)
        .background(
            LinearGradient(
                colors: [AgentPalette.surface, AgentPalette.lilac.opacity(0.10), AgentPalette.cyan.opacity(0.05)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 22, style: .continuous)
        )
        .agentSurface(radius: 22, tint: AgentPalette.lilac.opacity(0.08))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("runsAuditDashboard")
    }

    var auditSubtitle: String {
        if cachedStats.total == 0 { return "No tools have run yet" }
        if runs.count >= Self.fetchedRunLimit { return "Newest \(Self.fetchedRunLimit) fetched · older runs kept out of render path" }
        if hasOffscreenRuns { return "\(cachedMatchingRunCount) match · newest \(cachedFilteredRuns.count) shown" }
        if cachedStats.pending == 0 {
            return "\(cachedStats.total) logged · \(cachedStats.completed) done · \(cachedStats.failures) failed"
        }
        return "\(cachedStats.total) logged · \(cachedStats.completed) done · \(cachedStats.failures) failed · \(cachedStats.pending) pending"
    }


    var filterSelector: some View {
        HStack(spacing: 8) {
            ForEach(FilterType.allCases) { filter in
                Button {
                    withAnimation(.smooth(duration: 0.22)) {
                        restoredFilterTypeRawValue = filter.rawValue
                        searchFocused = false
                    }
                } label: {
                    Text(filter.rawValue)
                        .font(.caption.weight(.bold))
                        .padding(.horizontal, 14)
                        .frame(minHeight: AgentDesign.minimumTouchTarget)
                        .agentControlSurface(radius: 12, tint: AgentPalette.cyan, selected: activeFilterType == filter)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Show \(filter.rawValue.lowercased()) runs")
                .accessibilityIdentifier("runsFilter-\(filter.rawValue)")
            }
        }
    }

}

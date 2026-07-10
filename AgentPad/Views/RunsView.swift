import Foundation
import SwiftData
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

private func triggerRunsLightImpact() {
#if canImport(UIKit)
    UIImpactFeedbackGenerator(style: .light).impactOccurred()
#endif
}

struct RunsView: View {
    @Environment(\.modelContext) var modelContext
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    var runtime: AgentRuntime
    var project: Project
    let scopeProjectID: UUID?
    let scopeName: String
    let conversations: [Conversation]
    let openArtifactLandscapeFullScreen: (WorkspaceArtifact) -> Void
    let openTerminalRecord: (UUID, String, String) -> Void
    let openProject: () -> Void
    let approvePendingTool: () -> Void
    let rejectPendingTool: () -> Void
    let openChat: () -> Void
    let openConversationInForge: (UUID) -> Void
    @Query var runs: [ToolRun]
    @Query var missionRuns: [AgentRunRecord]
    @Query var terminalRecords: [TerminalCommandRecord]
    @SceneStorage("RunsView.filterType") var restoredFilterTypeRawValue = FilterType.all.rawValue
    @SceneStorage("RunsView.expandedRunID") var expandedRunIDString = ""

    @State var searchText = ""
    @State var debouncedSearchText = ""
    @State var previewArtifact: WorkspaceArtifact?
    @State var replayTarget: RunReplayTarget?

    @State var cachedStats = RunStats()
    @State var cachedLatestRun: RunRowData?
    @State var cachedAgentRunReceipts: [AgentRunReceiptData] = []
    @State var cachedFilteredRuns: [RunRowData] = []
    @State var cachedRunSections: [RunDaySection] = []
    @State var cachedMatchingRunCount = 0
    @State var runDeleteError: String?
    @FocusState var searchFocused: Bool
    @Namespace var historyChromeNamespace

    static let fetchedRunLimit = 500
    static let fetchedMissionRunLimit = 40
    static let visibleRunLimit = 80
    static let fetchedTerminalRecordLimit = 500
    static let searchableArgumentsLimit = 2_000
    static let searchableOutputLimit = 600
    let tabBarClearance: CGFloat = BottomDockMetrics.scrollClearance

    var activeFilterType: FilterType {
        FilterType(rawValue: restoredFilterTypeRawValue) ?? .all
    }

    var liveStatus: WorkspaceStatusSnapshot {
        WorkspaceStatusSnapshot(runtime: runtime)
    }

    var scopedProject: Project? {
        guard let scopeProjectID else { return nil }
        if project.id == scopeProjectID { return project }
        return conversations.lazy.compactMap(\.project).first { $0.id == scopeProjectID }
    }

    var artifactIterationPrompt: String {
        guard let scopedProject else {
            return "Ask NovaForge to inspect this General artifact and suggest the next concrete improvement."
        }
        return ProjectMissionSummarizer.summarize(project: scopedProject, context: modelContext).workflowSpine.iterationPrompt
    }

    init(
        runtime: AgentRuntime,
        project: Project,
        scopeProjectID: UUID?,
        scopeName: String,
        conversations: [Conversation],
        openArtifactLandscapeFullScreen: @escaping (WorkspaceArtifact) -> Void,
        openTerminalRecord: @escaping (UUID, String, String) -> Void,
        openProject: @escaping () -> Void,
        approvePendingTool: @escaping () -> Void,
        rejectPendingTool: @escaping () -> Void,
        openChat: @escaping () -> Void,
        openConversationInForge: @escaping (UUID) -> Void
    ) {
        self.runtime = runtime
        self.project = project
        self.scopeProjectID = scopeProjectID
        self.scopeName = scopeName
        self.conversations = conversations
        self.openArtifactLandscapeFullScreen = openArtifactLandscapeFullScreen
        self.openTerminalRecord = openTerminalRecord
        self.openProject = openProject
        self.approvePendingTool = approvePendingTool
        self.rejectPendingTool = rejectPendingTool
        self.openChat = openChat
        self.openConversationInForge = openConversationInForge

        var descriptor: FetchDescriptor<ToolRun>
        if let scopeProjectID {
            descriptor = FetchDescriptor<ToolRun>(
                predicate: #Predicate<ToolRun> { run in
                    run.project?.id == scopeProjectID
                },
                sortBy: [SortDescriptor(\ToolRun.createdAt, order: .reverse)]
            )
        } else {
            descriptor = FetchDescriptor<ToolRun>(
                predicate: #Predicate<ToolRun> { run in
                    run.project == nil
                },
                sortBy: [SortDescriptor(\ToolRun.createdAt, order: .reverse)]
            )
        }
        descriptor.fetchLimit = Self.fetchedRunLimit
        _runs = Query(descriptor)

        var missionDescriptor: FetchDescriptor<AgentRunRecord>
        if let scopeProjectIDString = scopeProjectID?.uuidString {
            missionDescriptor = FetchDescriptor<AgentRunRecord>(
                predicate: #Predicate<AgentRunRecord> { record in
                    record.projectIDString == scopeProjectIDString
                },
                sortBy: [SortDescriptor(\AgentRunRecord.createdAt, order: .reverse)]
            )
        } else {
            missionDescriptor = FetchDescriptor<AgentRunRecord>(
                predicate: #Predicate<AgentRunRecord> { record in
                    record.projectIDString == nil
                },
                sortBy: [SortDescriptor(\AgentRunRecord.createdAt, order: .reverse)]
            )
        }
        missionDescriptor.fetchLimit = Self.fetchedMissionRunLimit
        _missionRuns = Query(missionDescriptor)

        var terminalDescriptor: FetchDescriptor<TerminalCommandRecord>
        if let scopeProjectID {
            terminalDescriptor = FetchDescriptor<TerminalCommandRecord>(
                predicate: #Predicate<TerminalCommandRecord> { command in
                    command.project?.id == scopeProjectID
                },
                sortBy: [SortDescriptor(\TerminalCommandRecord.completedAt, order: .reverse)]
            )
        } else {
            terminalDescriptor = FetchDescriptor<TerminalCommandRecord>(
                predicate: #Predicate<TerminalCommandRecord> { command in
                    command.project == nil
                },
                sortBy: [SortDescriptor(\TerminalCommandRecord.completedAt, order: .reverse)]
            )
        }
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
        let receiptTitle: String
        let requestLine: String
        let outcomeLine: String
        let proofLine: String
        let proofDetail: String

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
            receiptTitle = Self.receiptTitle(for: run, artifact: resolvedArtifact, terminalProof: resolvedTerminalProof)
            requestLine = Self.requestLine(for: run, displayName: displayName, argumentSummary: argumentSummary)
            outcomeLine = Self.outcomeLine(for: run, artifact: resolvedArtifact, terminalProof: resolvedTerminalProof)
            proofLine = Self.proofLine(for: run, artifact: resolvedArtifact, terminalProof: resolvedTerminalProof)
            proofDetail = Self.proofDetail(for: run, artifact: resolvedArtifact, terminalProof: resolvedTerminalProof)
            elapsedText = Self.elapsedText(for: run)
            phaseTitle = Self.phaseTitle(for: run, artifact: resolvedArtifact, terminalProof: resolvedTerminalProof)
            phaseDetail = Self.phaseDetail(for: run, argumentSummary: argumentSummary, artifact: resolvedArtifact, terminalProof: resolvedTerminalProof)
            evidenceSummary = Self.evidenceSummary(for: run, artifact: resolvedArtifact, terminalProof: resolvedTerminalProof)
            logSummary = "\(argumentsByteText) args · \(outputByteText) output"
            nextActionTitle = Self.nextActionTitle(for: run, artifact: resolvedArtifact, terminalProof: resolvedTerminalProof)
            nextActionDetail = Self.nextActionDetail(for: run, artifact: resolvedArtifact, terminalProof: resolvedTerminalProof)
            timelinePhases = Self.timelinePhases(for: run, artifact: resolvedArtifact, terminalProof: resolvedTerminalProof)
        }

        private static func receiptTitle(
            for run: ToolRun,
            artifact: WorkspaceArtifact?,
            terminalProof: TerminalProofData?
        ) -> String {
            switch run.status {
            case .pendingApproval:
                return "Approval required"
            case .approved:
                return "Approved run active"
            case .rejected:
                return "Cancelled before change"
            case .failed:
                return "Failure preserved"
            case .completed:
                if artifact != nil { return "Proof artifact saved" }
                if terminalProof != nil { return "Command proof captured" }
                if run.isMutating { return "Workspace change recorded" }
                return "Run completed"
            }
        }

        private static func requestLine(
            for run: ToolRun,
            displayName: String,
            argumentSummary: String?
        ) -> String {
            guard let argumentSummary else { return displayName }
            return "\(displayName) · \(argumentSummary)"
        }

        private static func outcomeLine(
            for run: ToolRun,
            artifact: WorkspaceArtifact?,
            terminalProof: TerminalProofData?
        ) -> String {
            switch run.status {
            case .pendingApproval:
                return "Waiting for a decision before the tool changes anything."
            case .approved:
                return "Approved and waiting for the final tool result."
            case .rejected:
                return "The requested tool action was stopped before execution."
            case .failed:
                return firstUsefulOutputLine(from: run.output) ?? "The run failed without a saved output line."
            case .completed:
                if let artifact { return "Saved \(artifact.title) as reviewable proof." }
                if let terminalProof { return terminalProof.outputPreview.isEmpty ? "Terminal command completed." : terminalProof.terminalFocusQuery }
                return firstUsefulOutputLine(from: run.output) ?? "Completed with arguments and status retained."
            }
        }

        private static func proofLine(
            for run: ToolRun,
            artifact: WorkspaceArtifact?,
            terminalProof: TerminalProofData?
        ) -> String {
            var proof: [String] = []
            if artifact != nil { proof.append("artifact") }
            if terminalProof != nil { proof.append("terminal") }
            if run.isMutating { proof.append("workspace change") }
            if !run.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { proof.append("output") }
            if proof.isEmpty { return "Arguments retained" }
            return proof
                .map { String($0.prefix(1)).uppercased() + String($0.dropFirst()) }
                .joined(separator: " + ")
        }

        private static func proofDetail(
            for run: ToolRun,
            artifact: WorkspaceArtifact?,
            terminalProof: TerminalProofData?
        ) -> String {
            if let artifact { return artifact.path }
            if let terminalProof { return "\(terminalProof.outputLineCountText) · \(terminalProof.outputByteText)" }
            if !run.output.isEmpty { return byteText(for: run.output) }
            return byteText(for: run.argumentsJSON)
        }

        private static func firstUsefulOutputLine(from output: String) -> String? {
            output
                .split(separator: "\n", omittingEmptySubsequences: true)
                .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { !$0.isEmpty && !$0.hasPrefix("…") }
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

    /// A compact presentation snapshot for the canonical request-to-response
    /// receipt. Tool rows remain separate evidence and are linked only when
    /// the mission actually invoked one.
    struct AgentRunReceiptData: Identifiable {
        let id: UUID
        let conversationID: UUID?
        let status: AgentRunStatus
        let conversationTitle: String
        let requestExcerpt: String
        let outcomeLine: String
        let scopeLine: String
        let timingLine: String
        let engineLine: String
        let proofLine: String
        let errorLine: String?
        let linkedTool: RunRowData?
        let linkedToolCount: Int

        init(
            record: AgentRunRecord,
            scopeName: String,
            fallbackWorkspaceName: String,
            conversationTitle: String,
            requestExcerpt: String?,
            linkedTool: RunRowData?,
            linkedToolCount: Int,
            now: Date = Date()
        ) {
            id = record.id
            conversationID = record.conversationID
            status = record.status
            self.linkedTool = linkedTool
            self.linkedToolCount = linkedToolCount
            self.conversationTitle = conversationTitle
            let trimmedRequest = requestExcerpt?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            self.requestExcerpt = trimmedRequest.flatMap { value in
                value.isEmpty ? nil : value
            } ?? "Request text unavailable for this legacy receipt."

            let trimmedError = record.errorMessage?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let trimmedError, !trimmedError.isEmpty {
                errorLine = String(trimmedError.prefix(280))
            } else if let errorKind = record.errorKind {
                errorLine = errorKind.receiptTitle
            } else {
                errorLine = nil
            }

            outcomeLine = Self.outcomeLine(
                status: record.status,
                linkedToolCount: linkedToolCount
            )

            let workspaceName = record.workspaceName?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let resolvedWorkspaceName = workspaceName.flatMap { value in
                value.isEmpty ? nil : value
            } ?? fallbackWorkspaceName
            scopeLine = HistoryWorkspacePresentation.workspaceScopeLine(
                projectName: scopeName,
                workspaceName: resolvedWorkspaceName
            )

            let provider = record.provider?.displayName ?? "Provider not recorded"
            let trimmedModel = record.modelID?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let model = trimmedModel.flatMap { value in
                value.isEmpty ? nil : value
            } ?? "Model not recorded"
            engineLine = "\(provider) · \(model)"

            let start = record.startedAt ?? record.queuedAt ?? record.createdAt
            let end = record.status.isTerminal
                ? (record.completedAt ?? record.updatedAt)
                : now
            let createdTime = DateFormatter.localizedString(
                from: record.createdAt,
                dateStyle: .none,
                timeStyle: .short
            )
            timingLine = "\(Self.durationText(from: start, to: end)) · \(createdTime)"

            if linkedToolCount == 0 {
                proofLine = "Conversation receipt · no tool required"
            } else if let linkedTool {
                let count = linkedToolCount == 1 ? "1 linked tool" : "\(linkedToolCount) linked tools"
                proofLine = "\(count) · \(linkedTool.displayName)"
            } else {
                proofLine = linkedToolCount == 1 ? "1 linked tool receipt" : "\(linkedToolCount) linked tool receipts"
            }
        }

        var isLive: Bool {
            !status.isTerminal
        }

        private static func outcomeLine(
            status: AgentRunStatus,
            linkedToolCount: Int
        ) -> String {
            switch status {
            case .queued:
                return "Waiting for this mission to begin."
            case .running:
                return linkedToolCount == 0
                    ? "NovaForge is preparing the response."
                    : "NovaForge is working through linked tool evidence."
            case .awaitingApproval:
                return "Waiting for approval before the next workspace change."
            case .completed:
                return linkedToolCount == 0
                    ? "Response saved. This mission finished without needing a tool call."
                    : "Response saved with linked tool proof retained below."
            case .failed:
                return "The mission stopped before completion; its transcript and receipt were retained."
            case .cancelled:
                return "Stopped by request; the transcript remains saved."
            case .interrupted:
                return "The previous session ended before a final outcome was recorded."
            }
        }

        private static func durationText(from start: Date, to end: Date) -> String {
            let seconds = max(0, end.timeIntervalSince(start))
            if seconds < 1 {
                return String(format: "%.0fms", seconds * 1_000)
            }
            if seconds < 60 {
                return String(format: "%.1fs", seconds)
            }
            let minutes = Int(seconds / 60)
            let remainder = Int(seconds) % 60
            return remainder == 0 ? "\(minutes)m" : "\(minutes)m \(remainder)s"
        }
    }

    func updateCachedData() {
        AgentPerformance.event("Runs Filter Update")
        let signpostID = AgentPerformance.begin("Runs Cache Update")
        defer {
            AgentPerformance.end("Runs Cache Update", id: signpostID)
        }
        // Both project and General scopes are constrained by the fetch
        // descriptor, so the cache never scans another scope's tool log.
        let projectRuns = runs
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
        self.cachedAgentRunReceipts = makeAgentRunReceipts(
            linkedTerminalRecords: linkedTerminalRecords
        )
        self.cachedLatestRun = projectRuns.first.map { run in
            RunRowData(run: run, terminalRecord: linkedTerminalRecords[run.id.uuidString])
        }
        self.cachedFilteredRuns = filtered.prefix(Self.visibleRunLimit).map { run in
            RunRowData(run: run, terminalRecord: linkedTerminalRecords[run.id.uuidString])
        }
        self.cachedMatchingRunCount = filtered.count
        self.cachedRunSections = Self.daySections(from: cachedFilteredRuns)
        AgentPerformance.value("Runs Project Rows", Double(projectRuns.count))
        AgentPerformance.value("Runs Filtered Rows", Double(filtered.count))
    }

    func makeAgentRunReceipts(
        linkedTerminalRecords: [String: TerminalCommandRecord]
    ) -> [AgentRunReceiptData] {
        var toolsByAgentRunID: [String: [ToolRun]] = [:]
        toolsByAgentRunID.reserveCapacity(min(runs.count, Self.fetchedMissionRunLimit))
        for run in runs {
            guard let runIDString = run.runIDString else { continue }
            toolsByAgentRunID[runIDString, default: []].append(run)
        }

        let conversationByID = Dictionary(
            conversations.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let requestedMessageIDs = Set(missionRuns.compactMap(\.requestMessageID))
        var requestTextByID: [UUID: String] = [:]
        requestTextByID.reserveCapacity(requestedMessageIDs.count)
        if !requestedMessageIDs.isEmpty {
            conversationSearch: for conversation in conversations {
                for message in conversation.messages where requestedMessageIDs.contains(message.id) {
                    requestTextByID[message.id] = Self.requestExcerpt(from: message.content)
                    if requestTextByID.count == requestedMessageIDs.count {
                        break conversationSearch
                    }
                }
            }
        }

        let now = Date()
        return missionRuns.map { record in
            let linkedRuns = toolsByAgentRunID[record.id.uuidString] ?? []
            let linkedTool = linkedRuns.first.map { run in
                RunRowData(
                    run: run,
                    terminalRecord: linkedTerminalRecords[run.id.uuidString]
                )
            }
            let conversation = record.conversationID.flatMap { conversationByID[$0] }
            let rawConversationTitle = conversation?.title
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let conversationTitle = rawConversationTitle.flatMap { value in
                value.isEmpty ? nil : value
            } ?? (scopeProjectID == nil ? "General" : scopeName)
            let requestExcerpt = record.requestMessageID
                .flatMap { requestTextByID[$0] }
                ?? conversation.flatMap { conversation in
                    Self.legacyRequestExcerpt(
                        for: record,
                        in: conversation
                    )
                }
            return AgentRunReceiptData(
                record: record,
                scopeName: scopeName,
                fallbackWorkspaceName: runtime.workspace.workspaceName,
                conversationTitle: conversationTitle,
                requestExcerpt: requestExcerpt,
                linkedTool: linkedTool,
                linkedToolCount: linkedRuns.count,
                now: now
            )
        }
    }

    static func requestExcerpt(from content: String) -> String {
        let flattened = content
            .split(whereSeparator: \Character.isWhitespace)
            .joined(separator: " ")
        guard flattened.count > 180 else { return flattened }
        return String(flattened.prefix(177)) + "..."
    }

    static func legacyRequestExcerpt(
        for record: AgentRunRecord,
        in conversation: Conversation
    ) -> String? {
        if let exactMessage = conversation.messages.first(where: { message in
            message.role == .user && message.runID == record.id
        }) {
            return requestExcerpt(from: exactMessage.content)
        }
        let message = conversation.messages
            .filter { message in
                message.role == .user && message.createdAt <= record.createdAt
            }
            .max(by: { $0.createdAt < $1.createdAt })
        guard let message else { return nil }
        return requestExcerpt(from: message.content)
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
            project: scopedProject,
            context: modelContext
        )
        do {
            try modelContext.save()
        } catch {
            modelContext.rollback()
            runDeleteError = "NovaForge opened the artifact, but could not save the preview event. \(error.localizedDescription)"
        }
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
            withAnimation(reduceMotion ? nil : .smooth(duration: 0.24)) {
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
        runsAlertSurface
    }

    private var runsScrollSurface: some View {
        VStack(spacing: 0) {
            ScrollViewReader { scrollProxy in
                ScrollView {
                    LazyVStack(spacing: 14) {
                        runsScreenHeader
                            .padding(.bottom, 2)


                        historySurfaceMap

                        historyMissionReceiptSection(scrollProxy: scrollProxy)
                        historyToolEvidenceSection(scrollProxy: scrollProxy)
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
    }

    @ViewBuilder
    private func historyMissionReceiptSection(scrollProxy: ScrollViewProxy) -> some View {
        // Live mission state, same component as Forge — one vocabulary for
        // "the agent is doing something". The matching live canonical record
        // stays out of the settled receipt cards below.
        if shouldShowHistoryMissionStrip,
           ForgeMissionStrip.isVisible(
            scopedProject: scopedProjectForHistory,
            status: liveStatus,
            autoContinue: .disabled
           ) {
            ForgeMissionStrip(
                project: project,
                scopedProject: scopedProjectForHistory,
                status: liveStatus,
                autoContinue: .disabled,
                approve: approvePendingTool,
                reject: rejectPendingTool,
                stop: { runtime.stopGenerating(context: modelContext) },
                pauseAutoContinue: {},
                openDossier: openProject
            )
            .transition(reduceMotion ? .identity : .move(edge: .top).combined(with: .opacity))
        }

        if shouldShowRuntimeReceiptBanner {
            HistoryRuntimeReceiptBanner(
                state: runtime.runState,
                title: runtime.activityTitle,
                detail: runtime.activityDetail,
                openChat: openChat
            )
            .transition(reduceMotion ? .identity : .move(edge: .top).combined(with: .opacity))
        }

        if let prominentAgentRunReceipt {
            historyAgentRunOutcome(for: prominentAgentRunReceipt, scrollProxy: scrollProxy)
        } else if cachedAgentRunReceipts.isEmpty,
                  !shouldShowHistoryMissionStrip,
                  let cachedLatestRun {
            historyMissionOutcome(for: cachedLatestRun, scrollProxy: scrollProxy)
        }

        if !compactAgentRunReceipts.isEmpty {
            NovaSectionMark(
                title: "Mission receipts",
                detail: "\(compactAgentRunReceipts.count)",
                tint: AgentPalette.lilac
            )
            .padding(.top, 2)

            ForEach(compactAgentRunReceipts) { receipt in
                compactAgentRunReceipt(receipt, scrollProxy: scrollProxy)
            }
        }

        if cachedStats.total >= 6 {
            historyVaultSummary
        }
    }

    @ViewBuilder
    private func historyToolEvidenceSection(scrollProxy: ScrollViewProxy) -> some View {
        if cachedStats.total > 0 {
            historyToolbar
        }

        if cachedFilteredRuns.isEmpty {
            if shouldShowToolEmptyState {
                NovaGlassEmptyState(
                    symbol: emptyRunsSymbol,
                    title: emptyRunsTitle,
                    detail: emptyRunsDetail,
                    tint: emptyRunsTint,
                    actions: cachedStats.total == 0 ? [
                        NovaOrbitalEmptyState.Action(
                            title: "Ask NovaForge",
                            symbol: "bubble.left.and.bubble.right.fill",
                            tint: AgentPalette.cyan,
                            accessibilityIdentifier: "historyEmptyAskButton"
                        ) {
                            openChat()
                        }
                    ] : []
                )
                .padding(.top, -6)
            }
        } else {
            ForEach(cachedRunSections) { section in
                runDaySection(section, scrollProxy: scrollProxy)
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

    private var runsPresentationSurface: some View {
        runsScrollSurface
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
    }

    private var runsTaskSurface: some View {
        runsPresentationSurface
        .task {
            #if DEBUG || targetEnvironment(simulator)
            guard ProcessInfo.processInfo.arguments.contains("--open-run-replay-demo"),
                  replayTarget == nil else { return }
            for _ in 0..<24 {
                if let run = runs.first(where: { $0.status == .completed }) {
                    try? await Task.sleep(for: .milliseconds(700))
                    let linkedTerminalRecords = terminalRecordsBySourceRunID()
                    let row = RunRowData(
                        run: run,
                        terminalRecord: linkedTerminalRecords[run.id.uuidString]
                    )
                    replayTarget = RunReplayTarget(
                        id: run.id,
                        name: row.displayName,
                        status: row.status,
                        windowStart: row.createdAt.addingTimeInterval(-1),
                        windowEnd: (run.completedAt ?? row.createdAt).addingTimeInterval(1),
                        requestSummary: row.requestLine,
                        outcomeSummary: row.outcomeLine,
                        proofSummary: "\(row.proofLine) · \(row.proofDetail)",
                        durationText: row.elapsedText
                    )
                    return
                }
                try? await Task.sleep(for: .milliseconds(300))
            }
            #endif
        }
        .task(id: searchText) {
            let value = searchText
            try? await Task.sleep(for: .milliseconds(220))
            guard !Task.isCancelled else { return }
            debouncedSearchText = value
        }
    }

    private var runsChangeSurface: some View {
        runsTaskSurface
        .onChange(of: runs, initial: true) {
            updateCachedData()
        }
        .onChange(of: terminalRecords.count) {
            updateCachedData()
        }
        .onChange(of: missionReceiptCacheKey) {
            updateCachedData()
        }
        .onChange(of: conversationReceiptCacheKey) {
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
    }

    private var runsAlertSurface: some View {
        runsChangeSurface
        .alert(
            "History Receipt Error",
            isPresented: Binding(
                get: { runDeleteError != nil },
                set: { if !$0 { runDeleteError = nil } }
            )
        ) {
            Button("OK", role: .cancel) { runDeleteError = nil }
        } message: {
            Text(runDeleteError ?? "NovaForge could not save that receipt change.")
        }
    }

    var missionReceiptCacheKey: String {
        missionRuns.map { record in
            "\(record.id.uuidString):\(record.statusRawValue):\(record.updatedAt.timeIntervalSinceReferenceDate)"
        }
        .joined(separator: "|")
    }

    var conversationReceiptCacheKey: String {
        conversations.map { conversation in
            "\(conversation.id.uuidString):\(conversation.messageCount):\(conversation.updatedAt.timeIntervalSinceReferenceDate):\(conversation.title)"
        }
        .joined(separator: "|")
    }

    @ViewBuilder
    func runDaySection(_ section: RunDaySection, scrollProxy: ScrollViewProxy) -> some View {
        NovaSectionMark(
            title: section.title,
            detail: "\(section.rows.count)",
            tint: AgentPalette.lilac
        )
        .padding(.top, 2)

        ForEach(section.rows) { row in
            runCard(for: row, scrollProxy: scrollProxy)
                .id(row.id)
        }
    }

    func runCard(for row: RunRowData, scrollProxy: ScrollViewProxy) -> some View {
        RunCard(
            row: row,
            expanded: expansionBinding(for: row),
            // History's ForgeMissionStrip owns the live decision controls.
            // Tool rows remain durable evidence, never a second approval UI.
            hasLivePendingApproval: runtime.pendingTool != nil && !shouldShowHistoryMissionStrip,
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
            openChat: openChat,
            dismissSearch: {
                searchFocused = false
            },
            revealCard: { anchor in
                revealRun(row.id, anchor: anchor, proxy: scrollProxy)
            },
            openReplay: {
                openReplay(for: row)
            }
        )
    }

    func openReplay(for row: RunRowData) {
        replayTarget = RunReplayTarget(
            id: row.id,
            name: row.displayName,
            status: row.status,
            windowStart: row.createdAt,
            windowEnd: row.createdAt.addingTimeInterval(max(1, row.durationMs / 1_000) + 1),
            requestSummary: row.requestLine,
            outcomeSummary: row.outcomeLine,
            proofSummary: "\(row.proofLine) · \(row.proofDetail)",
            durationText: row.elapsedText
        )
    }

    func historyAgentRunOutcome(
        for receipt: AgentRunReceiptData,
        scrollProxy: ScrollViewProxy
    ) -> some View {
        let linkedTool = receipt.linkedTool
        return HistoryAgentRunOutcomePanel(
            receipt: receipt,
            showsToolReceipt: linkedTool != nil,
            openToolReceipt: {
                guard let linkedTool else { return }
                revealLinkedToolReceipt(linkedTool, scrollProxy: scrollProxy)
            },
            openForge: {
                openAgentRunInForge(receipt)
            }
        )
    }

    func compactAgentRunReceipt(
        _ receipt: AgentRunReceiptData,
        scrollProxy: ScrollViewProxy
    ) -> some View {
        let openToolReceipt: (() -> Void)?
        if let linkedTool = receipt.linkedTool {
            openToolReceipt = {
                revealLinkedToolReceipt(linkedTool, scrollProxy: scrollProxy)
            }
        } else {
            openToolReceipt = nil
        }
        return HistoryAgentRunCompactCard(
            receipt: receipt,
            openToolReceipt: openToolReceipt,
            openForge: {
                openAgentRunInForge(receipt)
            }
        )
    }

    func revealLinkedToolReceipt(
        _ linkedTool: RunRowData,
        scrollProxy: ScrollViewProxy
    ) {
        restoredFilterTypeRawValue = FilterType.all.rawValue
        searchText = ""
        debouncedSearchText = ""
        updateCachedData()
        expandedRunIDString = linkedTool.id.uuidString
        revealRun(linkedTool.id, anchor: .top, proxy: scrollProxy)
    }

    func openAgentRunInForge(_ receipt: AgentRunReceiptData) {
        if let conversationID = receipt.conversationID {
            openConversationInForge(conversationID)
        } else {
            openChat()
        }
    }

    func historyMissionOutcome(for row: RunRowData, scrollProxy: ScrollViewProxy) -> some View {
        HistoryMissionOutcomePanel(
            row: row,
            scopeLine: HistoryWorkspacePresentation.missionProvenanceLine(
                projectName: scopeName,
                workspaceName: runtime.workspace.workspaceName,
                toolName: row.displayName
            ),
            actionTitle: missionOutcomeActionTitle(for: row),
            actionSymbol: missionOutcomeActionSymbol(for: row),
            openReceipt: {
                restoredFilterTypeRawValue = FilterType.all.rawValue
                searchText = ""
                debouncedSearchText = ""
                updateCachedData()
                expandedRunIDString = row.id.uuidString
                revealRun(row.id, anchor: .top, proxy: scrollProxy)
            },
            performAction: {
                performMissionOutcomeAction(for: row)
            }
        )
    }

    func missionOutcomeActionTitle(for row: RunRowData) -> String {
        if row.artifact != nil { return "Open proof" }
        if row.terminalProof != nil { return "Open terminal" }
        switch row.status {
        case .pendingApproval, .approved:
            return "Open Forge"
        case .completed, .failed, .rejected:
            return "Replay"
        }
    }

    func missionOutcomeActionSymbol(for row: RunRowData) -> String {
        if row.artifact != nil { return "play.rectangle.fill" }
        if row.terminalProof != nil { return "terminal.fill" }
        switch row.status {
        case .pendingApproval, .approved:
            return "bubble.left.and.bubble.right.fill"
        case .completed, .failed, .rejected:
            return "memories"
        }
    }

    func performMissionOutcomeAction(for row: RunRowData) {
        if let artifact = row.artifact {
            preview(artifact)
            return
        }
        if let proof = row.terminalProof {
            openTerminalRecord(proof.id, proof.command, proof.terminalFocusQuery)
            return
        }
        switch row.status {
        case .pendingApproval, .approved:
            openChat()
        case .completed, .failed, .rejected:
            openReplay(for: row)
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
                project: run.project,
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
            runDeleteError = "Could not delete this history receipt. \(error.localizedDescription)"
            NovaHaptics.runFailed()
        }
    }

    var hasOffscreenRuns: Bool {
        cachedFilteredRuns.count < cachedMatchingRunCount ||
        (activeFilterType == .all && debouncedSearchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && runs.count >= Self.fetchedRunLimit)
    }

    var scopedProjectForHistory: Project? {
        guard scopeProjectID == project.id else { return nil }
        return project
    }

    var agentRunReceiptsForDisplay: [AgentRunReceiptData] {
        guard shouldShowHistoryMissionStrip else {
            return cachedAgentRunReceipts
        }
        return cachedAgentRunReceipts.filter { !$0.isLive }
    }

    var prominentAgentRunReceipt: AgentRunReceiptData? {
        guard !shouldShowHistoryMissionStrip else { return nil }
        return agentRunReceiptsForDisplay.first
    }

    var compactAgentRunReceipts: [AgentRunReceiptData] {
        if shouldShowHistoryMissionStrip {
            return agentRunReceiptsForDisplay
        }
        return Array(agentRunReceiptsForDisplay.dropFirst())
    }

    var shouldShowToolEmptyState: Bool {
        if cachedStats.total > 0 {
            return true
        }
        return cachedAgentRunReceipts.isEmpty && !shouldShowHistoryMissionStrip
    }

    var emptyRunsTitle: String {
        if cachedStats.total == 0, !missionRuns.isEmpty {
            return "No tool calls in this mission"
        }
        return cachedStats.total == 0 ? "No receipts yet" : "No matching history receipts"
    }

    var emptyRunsDetail: String {
        if cachedStats.total == 0 {
            if !missionRuns.isEmpty {
                return "The latest response completed without tools. Tool evidence will appear here when a mission reads or changes the workspace."
            }
            return "Tool calls, approvals, and terminal proof become receipts after NovaForge acts."
        }
        return "Adjust the search or filter to review more receipt evidence."
    }

    var emptyRunsSymbol: String {
        if cachedStats.total == 0, !missionRuns.isEmpty {
            return "text.bubble.fill"
        }
        return cachedStats.total == 0 ? "waveform.path.ecg.rectangle" : "line.3.horizontal.decrease.circle"
    }

    var emptyRunsTint: Color {
        if let status = missionRuns.first?.status, cachedStats.total == 0 {
            return status.receiptTint
        }
        return cachedStats.total == 0 ? AgentPalette.lilac : AgentPalette.secondaryText
    }

    var runsScreenHeader: some View {
        NovaScreenHeader(
            kicker: "History // \(scopeName)",
            title: "History",
            subtitle: runsHeaderStatusLine,
            symbol: "waveform.path.ecg",
            tint: AgentPalette.lilac,
            isActive: runtime.isWorking
        )
    }

    var historyVaultSummary: some View {
        HistoryVaultSummaryPanel(
            stats: cachedStats,
            visibleCount: cachedFilteredRuns.count,
            matchingCount: cachedMatchingRunCount,
            hasOffscreenRuns: hasOffscreenRuns
        )
    }

    var historySurfaceMap: some View {
        NovaSurfaceMap(
            title: "Proof loop",
            nodes: [
                NovaSurfaceMapNode(
                    title: "Receipts",
                    detail: "\(cachedStats.total) logged",
                    symbol: "waveform.path.ecg",
                    tint: AgentPalette.lilac,
                    isActive: activeFilterType == .all
                ),
                NovaSurfaceMapNode(
                    title: "Writes",
                    detail: "\(cachedStats.mutations) changes",
                    symbol: "square.and.pencil",
                    tint: AgentPalette.cyan,
                    isActive: activeFilterType == .writes
                ),
                NovaSurfaceMapNode(
                    title: "Failures",
                    detail: "\(cachedStats.failures) to review",
                    symbol: "exclamationmark.triangle.fill",
                    tint: cachedStats.failures > 0 ? AgentPalette.rose : AgentPalette.green,
                    isActive: activeFilterType == .failures || cachedStats.failures > 0
                ),
                NovaSurfaceMapNode(
                    title: "Replay",
                    detail: hasOffscreenRuns ? "\(cachedFilteredRuns.count) shown" : "Ready",
                    symbol: "play.rectangle.fill",
                    tint: AgentPalette.primaryAccent,
                    isActive: replayTarget != nil
                )
            ],
            tint: AgentPalette.lilac
        )
        .accessibilityIdentifier("historySurfaceMap")
    }

    var shouldShowHistoryMissionStrip: Bool {
        runtime.isWorking || runtime.pendingTool != nil
    }

    var shouldShowRuntimeReceiptBanner: Bool {
        switch runtime.runState {
        case .cancelled:
            let latestStatus = cachedAgentRunReceipts.first?.status
            return latestStatus != .cancelled && latestStatus != .interrupted
        case .failed(_):
            return cachedAgentRunReceipts.first?.status != .failed
        case .idle, .running, .waitingForApproval, .completed:
            return false
        }
    }

    var runsHeaderStatusLine: String {
        if cachedStats.total == 0 {
            if !cachedAgentRunReceipts.isEmpty {
                let count = cachedAgentRunReceipts.count
                return "\(count) mission receipt\(count == 1 ? "" : "s") · no tool evidence"
            }
            return "Every tool call becomes auditable proof"
        }
        var parts = ["\(cachedStats.total) logged"]
        if cachedStats.completed > 0 { parts.append("\(cachedStats.completed) done") }
        if cachedStats.failures > 0 { parts.append("\(cachedStats.failures) failed") }
        if cachedStats.pending > 0 { parts.append("\(cachedStats.pending) pending") }
        return parts.joined(separator: " · ")
    }

    /// Search and filters appear only once the log is big enough to need
    /// them — a five-run history doesn't need a five-stat audit dashboard.
    private var needsLogTools: Bool {
        cachedStats.total >= 6 || !debouncedSearchText.isEmpty || activeFilterType != .all
    }

    var historyToolbar: some View {
        GlassGroup(spacing: 10) {
            VStack(alignment: .leading, spacing: 13) {
                NovaSectionMark(title: "Receipts", detail: auditSectionDetail, tint: AgentPalette.lilac)

                if needsLogTools {
                    searchField

                    filterSelector
                }
            }
        }
        .padding(.top, 4)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("historyToolbar")
    }

    var searchField: some View {
        HStack(spacing: 9) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(AgentPalette.secondaryText)
                TextField("Search tool, status, path, or command", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(NovaType.body)
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
                    .accessibilityLabel("Clear receipt search")
                    .accessibilityIdentifier("runsSearchClearButton")
                }
            }
            .padding(.horizontal, 15)
            .frame(minHeight: AgentDesign.minimumTouchTarget + 2)
            .agentGlass(
                radius: (AgentDesign.minimumTouchTarget + 2) / 2,
                interactive: true,
                tint: AgentPalette.lilac.opacity(searchFocused ? 0.18 : 0.08)
            )
            .agentGlassEffectID("history-search", in: historyChromeNamespace)
    }

    var auditSectionDetail: String {
        if cachedStats.total == 0 { return "Standing by" }
        if hasOffscreenRuns { return "\(cachedFilteredRuns.count) of \(cachedMatchingRunCount) shown" }
        return "\(cachedFilteredRuns.count) shown"
    }

    var filterSelector: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(FilterType.allCases) { filter in
                    Button {
                        NovaHaptics.lensChanged()
                        withAnimation(reduceMotion ? nil : .smooth(duration: 0.22)) {
                            restoredFilterTypeRawValue = filter.rawValue
                            searchFocused = false
                        }
                    } label: {
                        Text(filter.rawValue)
                            .font(NovaType.caption)
                            .foregroundStyle(activeFilterType == filter ? AgentPalette.ink : AgentPalette.secondaryText)
                            .padding(.horizontal, 16)
                            .frame(minHeight: AgentDesign.minimumTouchTarget)
                            .contentShape(Capsule())
                    }
                    .agentInteractiveGlassButtonStyle(
                        radius: AgentDesign.minimumTouchTarget / 2,
                        tint: AgentPalette.cyan,
                        selected: activeFilterType == filter,
                        glassID: "history-filter-\(filter.rawValue)",
                        in: historyChromeNamespace
                    )
                    .accessibilityLabel("Show \(filter.rawValue.lowercased()) runs")
                    .accessibilityIdentifier("runsFilter-\(filter.rawValue)")
                }
            }
        }
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
    }

}

private struct HistoryAgentRunOutcomePanel: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Namespace private var glassNamespace

    let receipt: RunsView.AgentRunReceiptData
    let showsToolReceipt: Bool
    let openToolReceipt: () -> Void
    let openForge: () -> Void

    private var tint: Color { receipt.status.receiptTint }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 11) {
                Image(systemName: receipt.status.receiptSymbol)
                    .font(.system(size: 15, weight: .black))
                    .foregroundStyle(tint)
                    .frame(width: 38, height: 38)
                    .background(
                        tint.opacity(0.12),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                    )

                VStack(alignment: .leading, spacing: 3) {
                    Text("Latest mission receipt")
                        .font(NovaType.label)
                        .foregroundStyle(tint)
                        .textCase(.uppercase)
                        .tracking(0.8)
                    Text(receipt.conversationTitle)
                        .font(NovaType.title)
                        .foregroundStyle(AgentPalette.ink)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? 4 : 2)
                        .layoutPriority(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                AgentRunStatusBadge(status: receipt.status, tint: tint)
            }

            Text(receipt.outcomeLine)
                .font(NovaType.body)
                .foregroundStyle(AgentPalette.secondaryText)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)

            Label {
                Text(receipt.requestExcerpt)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "text.quote")
                    .foregroundStyle(AgentPalette.cyan)
            }
            .font(NovaType.body)
            .foregroundStyle(AgentPalette.secondaryText)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                AgentPalette.controlFill.opacity(0.38),
                in: RoundedRectangle(cornerRadius: 11, style: .continuous)
            )
            .accessibilityLabel("Request: \(receipt.requestExcerpt)")

            VStack(alignment: .leading, spacing: 7) {
                HistoryReceiptFact(
                    symbol: "scope",
                    label: "Scope",
                    value: receipt.scopeLine,
                    tint: AgentPalette.cyan
                )
                HistoryReceiptFact(
                    symbol: "cpu.fill",
                    label: "Engine",
                    value: receipt.engineLine,
                    tint: AgentPalette.blue
                )
                HistoryReceiptFact(
                    symbol: "timer",
                    label: "Timing",
                    value: receipt.timingLine,
                    tint: AgentPalette.lilac
                )
                HistoryReceiptFact(
                    symbol: receipt.linkedToolCount == 0 ? "text.bubble.fill" : "checkmark.seal.fill",
                    label: "Proof",
                    value: receipt.proofLine,
                    tint: AgentPalette.green
                )
            }

            if let errorLine = receipt.errorLine {
                Label {
                    Text(errorLine)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                }
                .font(NovaType.body)
                .foregroundStyle(AgentPalette.rose)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    AgentPalette.rose.opacity(0.08),
                    in: RoundedRectangle(cornerRadius: 11, style: .continuous)
                )
                .accessibilityLabel("Mission error: \(errorLine)")
            }

            GlassGroup(spacing: 9) {
                Group {
                    if dynamicTypeSize.isAccessibilitySize {
                        VStack(spacing: 8) {
                            if showsToolReceipt {
                                missionButton(
                                    title: "Tool receipt",
                                    symbol: "doc.text.magnifyingglass",
                                    tint: AgentPalette.lilac,
                                    action: openToolReceipt
                                )
                            }
                            missionButton(
                                title: "Open Forge",
                                symbol: "bubble.left.and.bubble.right.fill",
                                tint: tint,
                                action: openForge
                            )
                        }
                    } else {
                        HStack(spacing: 8) {
                            if showsToolReceipt {
                                missionButton(
                                    title: "Tool receipt",
                                    symbol: "doc.text.magnifyingglass",
                                    tint: AgentPalette.lilac,
                                    action: openToolReceipt
                                )
                            }
                            missionButton(
                                title: "Open Forge",
                                symbol: "bubble.left.and.bubble.right.fill",
                                tint: tint,
                                action: openForge
                            )
                        }
                    }
                }
            }
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .agentSurface(radius: 22, tint: tint.opacity(0.08), nativeGlass: true)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("historyLatestMissionOutcome")
    }

    private func missionButton(
        title: String,
        symbol: String,
        tint: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            triggerRunsLightImpact()
            action()
        } label: {
            Label(title, systemImage: symbol)
                .font(NovaType.caption)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, minHeight: AgentDesign.minimumTouchTarget)
        }
        .foregroundStyle(AgentPalette.ink)
        .agentInteractiveGlassButtonStyle(
            radius: 12,
            tint: tint,
            selected: true,
            glassID: "history-latest-\(title)",
            in: glassNamespace
        )
    }
}

private struct HistoryReceiptFact: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let symbol: String
    let label: String
    let value: String
    let tint: Color

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Image(systemName: symbol)
                            .font(NovaType.caption)
                            .foregroundStyle(tint)
                        Text(label)
                            .font(NovaType.label)
                            .foregroundStyle(AgentPalette.tertiaryText)
                            .textCase(.uppercase)
                    }
                    Text(value)
                        .font(NovaType.caption)
                        .foregroundStyle(AgentPalette.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: symbol)
                        .font(NovaType.label)
                        .foregroundStyle(tint)
                        .frame(width: 14)
                    Text(label)
                        .font(NovaType.label)
                        .foregroundStyle(AgentPalette.tertiaryText)
                        .textCase(.uppercase)
                        .lineLimit(1)
                        .minimumScaleFactor(0.76)
                        .frame(width: 82, alignment: .leading)
                    Text(value)
                        .font(NovaType.caption)
                        .foregroundStyle(AgentPalette.secondaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label): \(value)")
    }
}

private struct AgentRunStatusBadge: View {
    let status: AgentRunStatus
    let tint: Color

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: status.receiptSymbol)
                .font(NovaType.label)
            Text(status.receiptStatusTitle)
                .font(NovaType.label)
                .lineLimit(1)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(tint.opacity(0.12), in: Capsule())
        .overlay(
            Capsule()
                .stroke(tint.opacity(0.28), lineWidth: 0.8)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Mission status: \(status.receiptStatusTitle)")
    }
}

private struct HistoryAgentRunCompactCard: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let receipt: RunsView.AgentRunReceiptData
    let openToolReceipt: (() -> Void)?
    let openForge: () -> Void

    private var tint: Color { receipt.status.receiptTint }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: receipt.status.receiptSymbol)
                    .font(.system(size: 12, weight: .black))
                    .foregroundStyle(tint)
                    .frame(width: 31, height: 31)
                    .background(
                        tint.opacity(0.1),
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                    )

                VStack(alignment: .leading, spacing: 2) {
                    Text(receipt.conversationTitle)
                        .font(NovaType.headline)
                        .foregroundStyle(AgentPalette.ink)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 1)
                        .layoutPriority(1)
                    Text(receipt.timingLine)
                        .font(NovaType.label)
                        .foregroundStyle(AgentPalette.tertiaryText)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                AgentRunStatusBadge(status: receipt.status, tint: tint)
            }

            Text(receipt.requestExcerpt)
                .font(NovaType.body)
                .foregroundStyle(AgentPalette.secondaryText)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            Group {
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: 4) {
                        Label(receipt.scopeLine, systemImage: "scope")
                        Label(receipt.proofLine, systemImage: receipt.linkedToolCount == 0 ? "text.bubble.fill" : "checkmark.seal.fill")
                    }
                } else {
                    HStack(spacing: 6) {
                        Label(receipt.scopeLine, systemImage: "scope")
                        Spacer(minLength: 4)
                        Label(receipt.proofLine, systemImage: receipt.linkedToolCount == 0 ? "text.bubble.fill" : "checkmark.seal.fill")
                    }
                    .lineLimit(1)
                }
            }
            .font(NovaType.label)
            .foregroundStyle(AgentPalette.tertiaryText)

            if let errorLine = receipt.errorLine {
                Label(errorLine, systemImage: "exclamationmark.triangle.fill")
                    .font(NovaType.body)
                    .foregroundStyle(AgentPalette.rose)
                    .lineLimit(2)
            }

            Group {
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(spacing: 8) {
                        if let openToolReceipt {
                            compactButton(
                                title: "Tool receipt",
                                symbol: "doc.text.magnifyingglass",
                                tint: AgentPalette.lilac,
                                action: openToolReceipt
                            )
                        }
                        compactButton(
                            title: "Open Forge",
                            symbol: "bubble.left.and.bubble.right.fill",
                            tint: tint,
                            action: openForge
                        )
                    }
                } else {
                    HStack(spacing: 8) {
                        if let openToolReceipt {
                            compactButton(
                                title: "Tool receipt",
                                symbol: "doc.text.magnifyingglass",
                                tint: AgentPalette.lilac,
                                action: openToolReceipt
                            )
                        }
                        compactButton(
                            title: "Open Forge",
                            symbol: "bubble.left.and.bubble.right.fill",
                            tint: tint,
                            action: openForge
                        )
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .agentSurface(radius: 18, tint: tint.opacity(0.055))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("historyMissionReceipt-\(receipt.id.uuidString)")
    }

    private func compactButton(
        title: String,
        symbol: String,
        tint: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            triggerRunsLightImpact()
            action()
        } label: {
            Label(title, systemImage: symbol)
                .font(NovaType.caption)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, minHeight: AgentDesign.minimumTouchTarget)
        }
        .buttonStyle(.plain)
        .foregroundStyle(AgentPalette.ink)
        .agentControlSurface(radius: 11, tint: tint.opacity(0.11), selected: true)
    }
}

private struct HistoryMissionOutcomePanel: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Namespace private var glassNamespace

    let row: RunsView.RunRowData
    let scopeLine: String
    let actionTitle: String
    let actionSymbol: String
    let openReceipt: () -> Void
    let performAction: () -> Void

    private var tint: Color { row.status.tint }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 11) {
                Image(systemName: row.status.symbol)
                    .font(.system(size: 15, weight: .black))
                    .foregroundStyle(tint)
                    .frame(width: 38, height: 38)
                    .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                VStack(alignment: .leading, spacing: 3) {
                    Text("Latest mission outcome")
                        .font(NovaType.label)
                        .foregroundStyle(tint)
                        .textCase(.uppercase)
                        .tracking(0.8)
                    Text(row.receiptTitle)
                        .font(NovaType.title)
                        .foregroundStyle(AgentPalette.ink)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? 4 : 2)
                        .layoutPriority(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                RunStatusBadge(status: row.status, tint: tint)
            }

            Text(row.outcomeLine)
                .font(NovaType.body)
                .foregroundStyle(AgentPalette.secondaryText)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 7) {
                HistoryReceiptFact(
                    symbol: "scope",
                    label: "Scope",
                    value: scopeLine,
                    tint: AgentPalette.cyan
                )
                HistoryReceiptFact(
                    symbol: "timer",
                    label: "Timing",
                    value: "\(row.elapsedText) · \(row.createdTimeText)",
                    tint: AgentPalette.lilac
                )
                HistoryReceiptFact(
                    symbol: "checkmark.seal.fill",
                    label: "Provenance",
                    value: "\(row.proofLine) · \(row.proofDetail)",
                    tint: AgentPalette.green
                )
            }

            GlassGroup(spacing: 9) {
                Group {
                    if dynamicTypeSize.isAccessibilitySize {
                        VStack(spacing: 8) {
                            missionButton(title: "Receipt", symbol: "doc.text.magnifyingglass", tint: AgentPalette.lilac, action: openReceipt)
                            missionButton(title: actionTitle, symbol: actionSymbol, tint: tint, action: performAction)
                        }
                    } else {
                        HStack(spacing: 8) {
                            missionButton(title: "Receipt", symbol: "doc.text.magnifyingglass", tint: AgentPalette.lilac, action: openReceipt)
                            missionButton(title: actionTitle, symbol: actionSymbol, tint: tint, action: performAction)
                        }
                    }
                }
            }
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .agentSurface(radius: 22, tint: tint.opacity(0.08), nativeGlass: true)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("historyLatestMissionOutcome")
    }

    private func missionButton(
        title: String,
        symbol: String,
        tint: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            triggerRunsLightImpact()
            action()
        } label: {
            Label(title, systemImage: symbol)
                .font(NovaType.caption)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, minHeight: AgentDesign.minimumTouchTarget)
        }
        .foregroundStyle(AgentPalette.ink)
        .agentInteractiveGlassButtonStyle(
            radius: 12,
            tint: tint,
            selected: true,
            glassID: "history-outcome-\(title)",
            in: glassNamespace
        )
    }
}

private struct HistoryVaultSummaryPanel: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let stats: RunsView.RunStats
    let visibleCount: Int
    let matchingCount: Int
    let hasOffscreenRuns: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: "archivebox.fill")
                    .font(.system(size: 13, weight: .black))
                    .foregroundStyle(AgentPalette.lilac)
                    .frame(width: 30, height: 30)
                    .background(AgentPalette.lilac.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    Text("Replay Vault")
                        .font(NovaType.headline)
                        .foregroundStyle(AgentPalette.ink)
                    Text(vaultDetail)
                        .font(NovaType.caption)
                        .foregroundStyle(AgentPalette.secondaryText)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Group {
                if dynamicTypeSize.isAccessibilitySize {
                    LazyVGrid(
                        columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)],
                        spacing: 8
                    ) {
                        metrics
                    }
                } else {
                    HStack(spacing: 8) {
                        metrics
                    }
                }
            }
        }
        .padding(12)
        .background(AgentPalette.row.opacity(0.62), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(AgentPalette.lilac.opacity(0.18), lineWidth: 0.7)
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("historyVaultSummaryPanel")
    }

    private var vaultDetail: String {
        let shownText = hasOffscreenRuns ? "\(visibleCount) of \(matchingCount) shown" : "\(visibleCount) shown"
        return "\(shownText) · avg \(stats.averageDurationText) · failures stay retained"
    }

    @ViewBuilder
    private var metrics: some View {
        HistoryVaultMetric(value: "\(stats.total)", label: "Receipts", symbol: "doc.text.magnifyingglass", tint: AgentPalette.lilac)
        HistoryVaultMetric(value: stats.successRateText, label: "Complete", symbol: "checkmark.seal.fill", tint: AgentPalette.green)
        HistoryVaultMetric(value: "\(stats.failures)", label: "Failed", symbol: "exclamationmark.triangle.fill", tint: AgentPalette.rose)
        HistoryVaultMetric(value: "\(stats.pending)", label: "Approval", symbol: "checkmark.shield.fill", tint: AgentPalette.cyan)
    }
}

private struct HistoryVaultMetric: View {
    let value: String
    let label: String
    let symbol: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: symbol)
                    .font(NovaType.label)
                Text(label)
                    .font(NovaType.label)
                    .textCase(.uppercase)
            }
            .foregroundStyle(AgentPalette.tertiaryText)

            Text(value)
                .font(NovaType.readoutSmall)
                .monospacedDigit()
                .foregroundStyle(tint)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        .background(tint.opacity(0.075), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private struct HistoryRuntimeReceiptBanner: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let state: AgentRunState
    let title: String
    let detail: String
    let openChat: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .black))
                    .foregroundStyle(tint)
                    .frame(width: 31, height: 31)
                    .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    Text(stateTitle)
                        .font(NovaType.headline)
                        .foregroundStyle(AgentPalette.ink)
                    Text(stateDetail)
                        .font(NovaType.body)
                        .foregroundStyle(AgentPalette.secondaryText)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? 4 : 2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(spacing: 8) {
                switch state {
                case .cancelled:
                    runtimeButton(cancelledPrimaryTitle, symbol: "arrow.clockwise", tint: AgentPalette.lilac, action: openChat)
                case .failed(_):
                    runtimeButton("Open Forge", symbol: "bubble.left.and.bubble.right.fill", tint: AgentPalette.cyan, action: openChat)
                case .idle, .running, .waitingForApproval, .completed:
                    EmptyView()
                }
            }
        }
        .padding(12)
        .background(tint.opacity(0.07), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(tint.opacity(0.22), lineWidth: 0.75)
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("historyRuntimeReceiptBanner")
    }

    private var stateTitle: String {
        switch state {
        case .running:
            return "Run in progress"
        case .waitingForApproval:
            return "Approval needed"
        case .cancelled:
            return isPaused ? "Run paused" : "Run cancelled"
        case .failed(_):
            return "Run failed"
        case .completed:
            return "Run completed"
        case .idle:
            return "Ready"
        }
    }

    private var stateDetail: String {
        switch state {
        case .failed(let message):
            return message
        case .cancelled:
            return detail.isEmpty ? "Progress was saved where possible." : detail
        default:
            if !detail.isEmpty { return detail }
            return title
        }
    }

    private var cancelledPrimaryTitle: String {
        isPaused ? "Continue" : "Resume"
    }

    private var isPaused: Bool {
        title.localizedCaseInsensitiveContains("paused") ||
            detail.localizedCaseInsensitiveContains("paused")
    }

    private var symbol: String {
        switch state {
        case .running:
            return "waveform.path.ecg"
        case .waitingForApproval:
            return "checkmark.shield.fill"
        case .cancelled:
            return isPaused ? "pause.circle.fill" : "xmark.octagon.fill"
        case .failed(_):
            return "exclamationmark.triangle.fill"
        case .completed:
            return "checkmark.seal.fill"
        case .idle:
            return "archivebox.fill"
        }
    }

    private var tint: Color {
        switch state {
        case .running:
            return AgentPalette.green
        case .waitingForApproval:
            return AgentPalette.cyan
        case .cancelled:
            return isPaused ? AgentPalette.lilac : AgentPalette.rose
        case .failed(_):
            return AgentPalette.rose
        case .completed:
            return AgentPalette.green
        case .idle:
            return AgentPalette.lilac
        }
    }

    private func runtimeButton(_ title: String, symbol: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button {
            NovaHaptics.tick()
            action()
        } label: {
            Label(title, systemImage: symbol)
                .font(NovaType.caption)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, minHeight: AgentDesign.minimumTouchTarget)
        }
        .buttonStyle(.plain)
        .foregroundStyle(AgentPalette.ink)
        .agentControlSurface(radius: 11, tint: tint.opacity(0.14), selected: true)
    }
}


extension RunsView {
    /// One calendar day of run receipts. Day marks give the log narrative
    /// structure ("what happened today vs. Tuesday") without any dashboard
    /// chrome — the receipts stay the content.
    struct RunDaySection: Identifiable, Equatable {
        let id: String
        let title: String
        let rows: [RunRowData]
    }

    static func daySections(from rows: [RunRowData]) -> [RunDaySection] {
        guard !rows.isEmpty else { return [] }
        let calendar = Calendar.current
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE, MMM d"
        var sections: [RunDaySection] = []
        var currentDay: Date?
        var currentRows: [RunRowData] = []

        func flush() {
            guard let day = currentDay, !currentRows.isEmpty else { return }
            let title: String
            if calendar.isDateInToday(day) {
                title = "Today"
            } else if calendar.isDateInYesterday(day) {
                title = "Yesterday"
            } else {
                title = formatter.string(from: day)
            }
            sections.append(RunDaySection(
                id: ISO8601DateFormatter().string(from: day),
                title: title,
                rows: currentRows
            ))
        }

        for row in rows {
            let day = calendar.startOfDay(for: row.createdAt)
            if day != currentDay {
                flush()
                currentDay = day
                currentRows = []
            }
            currentRows.append(row)
        }
        flush()
        return sections
    }
}

private extension AgentRunStatus {
    var receiptStatusTitle: String {
        switch self {
        case .queued: "Queued"
        case .running: "Running"
        case .awaitingApproval: "Approval"
        case .completed: "Completed"
        case .failed: "Failed"
        case .cancelled: "Cancelled"
        case .interrupted: "Interrupted"
        }
    }

    var receiptSymbol: String {
        switch self {
        case .queued: "clock.fill"
        case .running: "waveform.path.ecg"
        case .awaitingApproval: "checkmark.shield.fill"
        case .completed: "checkmark.seal.fill"
        case .failed: "exclamationmark.triangle.fill"
        case .cancelled: "xmark.octagon.fill"
        case .interrupted: "bolt.slash.fill"
        }
    }

    var receiptTint: Color {
        switch self {
        case .queued:
            AgentPalette.secondaryText
        case .running:
            AgentPalette.lilac
        case .awaitingApproval:
            AgentPalette.cyan
        case .completed:
            AgentPalette.green
        case .failed, .cancelled, .interrupted:
            AgentPalette.rose
        }
    }
}

private extension AgentRunErrorKind {
    var receiptTitle: String {
        switch self {
        case .invalidRequest: "Invalid request"
        case .provider: "Provider request failed"
        case .tool: "Tool execution failed"
        case .approvalRejected: "Approval was rejected"
        case .workspaceConflict: "Workspace execution conflict"
        case .persistence: "Receipt persistence failed"
        case .cancelled: "Mission was cancelled"
        case .interrupted: "Mission was interrupted"
        case .unknown: "Unknown mission error"
        }
    }
}

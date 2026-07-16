import AgentPolicy
import AgentTools
import SwiftData
import SwiftUI
import UIKit

struct SearchResultItem: Identifiable, Hashable, Sendable {
    let fileName: String
    let relativePath: String
    let lineNumber: Int
    let lineContent: String

    var id: String { "\(relativePath):\(lineNumber):\(lineContent)" }
}

struct FileSearchStats: Equatable, Sendable {
    var scannedFiles = 0
    var skippedLargeFiles = 0
    var skippedUnsafePaths = 0
    var searchedDirectories = 0
    var capped = false
}

struct FileEditTarget: Identifiable, Hashable, Sendable {
    let item: FileItem
    var focusedLineNumber: Int?

    var id: String {
        "\(item.id):\(focusedLineNumber.map(String.init) ?? "start")"
    }
}

struct FilesView: View {
    @Environment(\.modelContext) var modelContext
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    @Environment(\.dynamicTypeSize) var dynamicTypeSize
    @Query var settingsList: [AgentSettings]
    /// Evidence is queried by the selected chat scope rather than read through
    /// the active workspace project relationship. That keeps General truly
    /// general: it sees its own nil-project evidence, never whichever project
    /// happens to own the physical workspace.
    @Query var scopedArtifactRecords: [ProjectArtifact]
    @Query var scopedFileChangeRecords: [ProjectFileChange]
    @Query var scopedTerminalCommandRecords: [TerminalCommandRecord]
    @Query var scopedToolRunRecords: [ToolRun]
    @Query var scopedEventRecords: [ProjectEvent]
    
    var runtime: AgentRuntime
    /// The active project still owns the physical workspace selection, while
    /// this optional project represents the selected chat's evidence scope.
    /// `nil` is the explicit General scope and must not borrow project proof.
    var project: Project
    var scopeProject: Project?
    let scopeConversationID: UUID
    let scopeTitle: String
    let isWorkspaceRoutingLocked: () -> Bool
    let openArtifactLandscapeFullScreen: (WorkspaceArtifact) -> Void
    let openChat: () -> Void
    @SceneStorage("novaforge.files.currentPath") var currentPath = ""
    @SceneStorage("novaforge.files.selectedMemoryItemID") var selectedMemoryItemID = ""
    @AppStorage("novaforge.files.workbenchLens") var workbenchLensRawValue = FileWorkbenchLens.all.rawValue
    @AppStorage("novaforge.files.inspectorMode") var inspectorModeRawValue = FileInspectorMode.details.rawValue
    @AppStorage("novaforge.files.gridLayout") var isGridLayout = false
    @State var items: [FileRowData] = []
    @State var editingTarget: FileEditTarget? = nil
    @State var pendingSearchOpenTarget: FileEditTarget? = nil
    @State var previewArtifact: WorkspaceArtifact? = nil
    @State var comparisonDraft: FileComparisonDraft? = nil
    @State var relatedContextDraft: FileRelatedContextDraft? = nil
    @State var importantMemoryPaths: Set<String> = []
    @State var pinnedMemoryPaths: Set<String> = []
    @State var transientNotice: String?
    @State var showingCreate = false
    
    @State var workspaces: [String] = []
    @State var showingCreateWorkspace = false
    @State var newWorkspaceName = ""
    
    // Search panel options
    @State var searchQuery = ""
    @State var showingSearch = false
    @State var searchResults: [SearchResultItem] = []
    @State var searchStats = FileSearchStats()
    @State var isSearching = false
    @State var hasSearchedFiles = false
    @State var lastSearchQuery = ""
    @State var searchErrorMessage: String?
    @State var activeSearchID: UUID?
    @State var searchTask: Task<Void, Never>?
    @State var reloadTask: Task<Void, Never>?
    @State var fileActionTask: Task<Void, Never>?
    @State var workspaceSwitchTask: Task<Void, Never>?
    @State var fileActionStatus: String?
    @State var fileActionError: String?
    @State var fileLoadError: String?
    @State var workspaceSaveError: String?
    @State var pendingDeleteItem: FileItem?
    @State var didSeedFileStress = false
    @State var isSeedingFileStress = false
    @State var isFileStressFixtureReady = false
    @State var didOpenDebugArtifactPreview = false
    @State var didOpenFilesSurfaceDemo = false
    @FocusState var searchFocused: Bool
    
    var settings: AgentSettings? { settingsList.first }
    @State var isExporting = false
    @State var recentCutoff = Date().addingTimeInterval(-300)
    @State var cachedStats = FileStats()
    @State var cachedProjectMemoryItems: [ProjectMemoryItem] = []
    @Namespace var workspaceGlassNamespace

    let tabBarClearance: CGFloat = BottomDockMetrics.scrollClearance
    let searchResultLimit = 200

    @MainActor
    @discardableResult
    func performFilesMutation(
        operationID: UUID,
        operation: FilesCanonicalMutationOperation
    ) async throws -> AgentPolicyMutationReceipt {
        let workspace = runtime.workspace
        let policyRuntime = AgentPolicyMutationRuntime.shared
        let executionContext = try policyRuntime.makeExecutionContext(
            workspace: workspace,
            operationID: operationID,
            idempotencyKey: filesMutationIdempotencyKey(
                operation: operation,
                operationID: operationID
            ),
            conversationID: scopeConversationID,
            projectID: project.id,
            sessionID: "files"
        )
        return try await policyRuntime.coordinator().performFiles(
            context: executionContext,
            operation: operation
        )
    }

    @MainActor
    @discardableResult
    func performFilesMutation(
        operationID: UUID,
        operation: FilesPolicyMutationOperation
    ) async throws -> AgentPolicyMutationReceipt {
        let workspace = runtime.workspace
        let policyRuntime = AgentPolicyMutationRuntime.shared
        let executionContext = try policyRuntime.makeExecutionContext(
            workspace: workspace,
            operationID: operationID,
            idempotencyKey: filesMutationIdempotencyKey(
                operation: operation,
                operationID: operationID
            ),
            conversationID: scopeConversationID,
            projectID: project.id,
            sessionID: "files"
        )
        return try await policyRuntime.coordinator().performFiles(
            context: executionContext,
            operation: operation
        )
    }

    func filesMutationFailureMessage(
        action: String,
        error: Error
    ) -> String? {
        if error is CancellationError { return nil }
        if (error as? AgentPolicyMutationServiceError) == .cancelled {
            return nil
        }
        return "\(action): \(error.localizedDescription)"
    }

    private func filesMutationIdempotencyKey(
        operation: FilesCanonicalMutationOperation,
        operationID: UUID
    ) -> String {
        let kind: String
        switch operation {
        case .writeFile: kind = "write-file"
        case .deletePath: kind = "delete-path"
        case .movePath: kind = "move-path"
        case .copyPath: kind = "copy-path"
        case .makeDirectory: kind = "make-directory"
        }
        return filesMutationIdempotencyKey(
            kind: kind,
            operationID: operationID
        )
    }

    private func filesMutationIdempotencyKey(
        operation: FilesPolicyMutationOperation,
        operationID: UUID
    ) -> String {
        let kind: String
        switch operation {
        case .createFile: kind = "create-file"
        case .touchFile: kind = "touch-file"
        }
        return filesMutationIdempotencyKey(
            kind: kind,
            operationID: operationID
        )
    }

    private func filesMutationIdempotencyKey(
        kind: String,
        operationID: UUID
    ) -> String {
        "files.\(kind).v1:\(operationID.uuidString.lowercased())"
    }

    init(
        runtime: AgentRuntime,
        project: Project,
        scopeProject: Project?,
        scopeConversationID: UUID,
        scopeTitle: String,
        isWorkspaceRoutingLocked: @escaping () -> Bool,
        openArtifactLandscapeFullScreen: @escaping (WorkspaceArtifact) -> Void,
        openChat: @escaping () -> Void
    ) {
        self.runtime = runtime
        self.project = project
        self.scopeProject = scopeProject
        self.scopeConversationID = scopeConversationID
        self.scopeTitle = scopeTitle
        self.isWorkspaceRoutingLocked = isWorkspaceRoutingLocked
        self.openArtifactLandscapeFullScreen = openArtifactLandscapeFullScreen
        self.openChat = openChat

        let scopeProjectID = scopeProject?.id
        _scopedArtifactRecords = Query(Self.artifactRecordsDescriptor(scopeProjectID: scopeProjectID))
        _scopedFileChangeRecords = Query(Self.fileChangeRecordsDescriptor(scopeProjectID: scopeProjectID))
        _scopedTerminalCommandRecords = Query(Self.terminalCommandRecordsDescriptor(scopeProjectID: scopeProjectID))
        _scopedToolRunRecords = Query(Self.toolRunRecordsDescriptor(scopeProjectID: scopeProjectID))
        _scopedEventRecords = Query(Self.eventRecordsDescriptor(scopeProjectID: scopeProjectID))
    }

    /// Query predicates intentionally make `nil` a first-class scope. Do not
    /// replace these with a project relationship fallback: General evidence is
    /// durable work in its own right and project evidence must remain exact.
    private static func artifactRecordsDescriptor(scopeProjectID: UUID?) -> FetchDescriptor<ProjectArtifact> {
        if let scopeProjectID {
            return FetchDescriptor(
                predicate: #Predicate<ProjectArtifact> { artifact in
                    artifact.project?.id == scopeProjectID
                },
                sortBy: [SortDescriptor(\ProjectArtifact.updatedAt, order: .reverse)]
            )
        }
        return FetchDescriptor(
            predicate: #Predicate<ProjectArtifact> { artifact in
                artifact.project == nil
            },
            sortBy: [SortDescriptor(\ProjectArtifact.updatedAt, order: .reverse)]
        )
    }

    private static func fileChangeRecordsDescriptor(scopeProjectID: UUID?) -> FetchDescriptor<ProjectFileChange> {
        if let scopeProjectID {
            return FetchDescriptor(
                predicate: #Predicate<ProjectFileChange> { change in
                    change.project?.id == scopeProjectID
                },
                sortBy: [SortDescriptor(\ProjectFileChange.createdAt, order: .reverse)]
            )
        }
        return FetchDescriptor(
            predicate: #Predicate<ProjectFileChange> { change in
                change.project == nil
            },
            sortBy: [SortDescriptor(\ProjectFileChange.createdAt, order: .reverse)]
        )
    }

    private static func terminalCommandRecordsDescriptor(scopeProjectID: UUID?) -> FetchDescriptor<TerminalCommandRecord> {
        if let scopeProjectID {
            return FetchDescriptor(
                predicate: #Predicate<TerminalCommandRecord> { record in
                    record.project?.id == scopeProjectID
                },
                sortBy: [SortDescriptor(\TerminalCommandRecord.completedAt, order: .reverse)]
            )
        }
        return FetchDescriptor(
            predicate: #Predicate<TerminalCommandRecord> { record in
                record.project == nil
            },
            sortBy: [SortDescriptor(\TerminalCommandRecord.completedAt, order: .reverse)]
        )
    }

    private static func toolRunRecordsDescriptor(scopeProjectID: UUID?) -> FetchDescriptor<ToolRun> {
        if let scopeProjectID {
            return FetchDescriptor(
                predicate: #Predicate<ToolRun> { run in
                    run.project?.id == scopeProjectID
                },
                sortBy: [SortDescriptor(\ToolRun.createdAt, order: .reverse)]
            )
        }
        return FetchDescriptor(
            predicate: #Predicate<ToolRun> { run in
                run.project == nil
            },
            sortBy: [SortDescriptor(\ToolRun.createdAt, order: .reverse)]
        )
    }

    private static func eventRecordsDescriptor(scopeProjectID: UUID?) -> FetchDescriptor<ProjectEvent> {
        if let scopeProjectID {
            return FetchDescriptor(
                predicate: #Predicate<ProjectEvent> { event in
                    event.project?.id == scopeProjectID
                },
                sortBy: [SortDescriptor(\ProjectEvent.createdAt, order: .reverse)]
            )
        }
        return FetchDescriptor(
            predicate: #Predicate<ProjectEvent> { event in
                event.project == nil
            },
            sortBy: [SortDescriptor(\ProjectEvent.createdAt, order: .reverse)]
        )
    }

    var artifactIterationPrompt: String {
        guard let scopeProject else {
            return "Continue this General session in Forge with the workspace evidence you reviewed."
        }
        return ProjectMissionSummarizer.summarize(project: scopeProject, context: modelContext).workflowSpine.iterationPrompt
    }

    struct FileStats {
        var folderCount = 0
        var fileCount = 0
        var totalBytes: Int64 = 0
        var totalBytesText = "0 B"
        var previewableCount = 0
        var recentCount = 0
        var newestName: String?
        var newestDate: Date?
    }

    enum FileVisualKind: Hashable, Sendable {
        case folder
        case preview
        case swift
        case markdown
        case json
        case shell
        case text
        case generic

        var symbolName: String {
            switch self {
            case .folder: return "folder.fill"
            case .preview: return "play.rectangle.fill"
            case .swift: return "swift"
            case .markdown: return "doc.plaintext.fill"
            case .json: return "braces"
            case .shell: return "terminal.fill"
            case .text: return "doc.text.fill"
            case .generic: return "doc.fill"
            }
        }

        var tint: Color {
            switch self {
            case .folder, .markdown, .generic:
                return AgentPalette.cyan
            case .preview, .json:
                return AgentPalette.green
            case .swift:
                return AgentPalette.lilac
            case .shell:
                return AgentPalette.indigo
            case .text:
                return .secondary
            }
        }
    }

    struct FileRowData: Identifiable, Hashable, Sendable {
        let item: FileItem
        let id: String
        let kindText: String
        let extensionText: String?
        let visualKind: FileVisualKind
        let isRecent: Bool
        let isPreviewable: Bool
        let modifiedText: String

        init(item: FileItem, recentCutoff: Date) {
            self.item = item
            self.id = item.id
            let rawExtension = URL(fileURLWithPath: item.name).pathExtension
            let normalizedExtension = rawExtension.lowercased()
            self.extensionText = rawExtension.isEmpty || item.isDirectory ? nil : rawExtension.uppercased()
            self.visualKind = Self.visualKind(isDirectory: item.isDirectory, extensionText: normalizedExtension)
            self.kindText = item.isDirectory ? "Folder" : FilesView.byteCountString(item.byteCount)
            self.isRecent = item.modifiedAt.map { $0 > recentCutoff } ?? false
            self.isPreviewable = !item.isDirectory && WorkspaceArtifact(path: item.relativePath).isReadablePreviewArtifact
            self.modifiedText = item.modifiedAt.map(Self.relativeModifiedText) ?? "No timestamp"
        }

        private static func visualKind(isDirectory: Bool, extensionText: String) -> FileVisualKind {
            if isDirectory { return .folder }
            switch extensionText {
            case "html", "htm", "svg":
                return .preview
            case "swift":
                return .swift
            case "md", "markdown":
                return .markdown
            case "json":
                return .json
            case "sh", "bash", "zsh":
                return .shell
            case "txt":
                return .text
            default:
                return .generic
            }
        }

        private static func relativeModifiedText(_ date: Date) -> String {
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .abbreviated
            return formatter.localizedString(for: date, relativeTo: Date())
        }
    }

    enum FileWorkbenchLens: String, CaseIterable, Identifiable {
        case all
        case recent
        case important
        case screenshots
        case verification
        case generated
        case failed
        case pinned

        var id: String { rawValue }

        var title: String {
            switch self {
            case .all: return "All"
            case .recent: return "Recent"
            case .important: return "Important"
            case .screenshots: return "Screens"
            case .verification: return "Proof"
            case .generated: return "Generated"
            case .failed: return "Failed"
            case .pinned: return "Pinned"
            }
        }

        var symbol: String {
            switch self {
            case .all: return "rectangle.stack.fill"
            case .recent: return "clock.fill"
            case .important: return "star.fill"
            case .screenshots: return "camera.viewfinder"
            case .verification: return "checkmark.seal.fill"
            case .generated: return "sparkles"
            case .failed: return "exclamationmark.triangle.fill"
            case .pinned: return "pin.fill"
            }
        }

        var tint: Color {
            switch self {
            case .all, .recent, .generated: return AgentPalette.cyan
            case .important, .pinned: return AgentPalette.warning
            case .screenshots, .verification: return AgentPalette.green
            case .failed: return AgentPalette.rose
            }
        }
    }

    enum FileInspectorMode: String, CaseIterable, Identifiable {
        case details
        case review

        var id: String { rawValue }

        var title: String {
            switch self {
            case .details: return "Details"
            case .review: return "Review"
            }
        }

        var symbol: String {
            switch self {
            case .details: return "info.circle.fill"
            case .review: return "checklist.checked"
            }
        }
    }

    enum ProjectMemoryGroup: String, CaseIterable, Identifiable {
        case changed
        case artifacts
        case screenshots
        case verification
        case documents
        case scripts
        case source
        case folders
        case files

        var id: String { rawValue }

        var title: String {
            switch self {
            case .changed: return "Changed Files"
            case .artifacts: return "Artifacts"
            case .screenshots: return "Screenshots"
            case .verification: return "Verification Evidence"
            case .documents: return "Docs & Reports"
            case .scripts: return "Scripts"
            case .source: return "Source"
            case .folders: return "Folders"
            case .files: return "Other Files"
            }
        }

        var subtitle: String {
            switch self {
            case .changed: return "Review what moved"
            case .artifacts: return "Generated outputs"
            case .screenshots: return "Visual proof"
            case .verification: return "QA, proof, logs"
            case .documents: return "Markdown, reports, notes"
            case .scripts: return "Shell and automation"
            case .source: return "Code surfaces"
            case .folders: return "Workspace navigation"
            case .files: return "Everything else"
            }
        }

        var symbol: String {
            switch self {
            case .changed: return "doc.badge.gearshape.fill"
            case .artifacts: return "shippingbox.fill"
            case .screenshots: return "camera.viewfinder"
            case .verification: return "checkmark.seal.fill"
            case .documents: return "doc.plaintext.fill"
            case .scripts: return "terminal.fill"
            case .source: return "chevron.left.forwardslash.chevron.right"
            case .folders: return "folder.fill"
            case .files: return "doc.fill"
            }
        }

        var tint: Color {
            switch self {
            case .changed, .source: return AgentPalette.cyan
            case .artifacts, .screenshots, .verification: return AgentPalette.green
            case .documents: return AgentPalette.lilac
            case .scripts: return AgentPalette.indigo
            case .folders, .files: return AgentPalette.secondaryText
            }
        }

        var priority: Int {
            switch self {
            case .changed: return 0
            case .artifacts: return 1
            case .screenshots: return 2
            case .verification: return 3
            case .documents: return 4
            case .scripts: return 5
            case .source: return 6
            case .folders: return 7
            case .files: return 8
            }
        }
    }

    enum ProjectMemoryRisk: String {
        case low
        case medium
        case elevated
        case high

        var title: String {
            switch self {
            case .low: return "Low"
            case .medium: return "Medium"
            case .elevated: return "Elevated"
            case .high: return "High"
            }
        }

        var detail: String {
            switch self {
            case .low: return "Mostly evidence or supporting material."
            case .medium: return "Review behavior or generated output before relying on it."
            case .elevated: return "Touches app code, models, services, or scripts."
            case .high: return "Failed evidence or risky project surface needs attention."
            }
        }

        var symbol: String {
            switch self {
            case .low: return "checkmark.circle.fill"
            case .medium: return "exclamationmark.circle.fill"
            case .elevated: return "exclamationmark.triangle.fill"
            case .high: return "xmark.octagon.fill"
            }
        }

        var tint: Color {
            switch self {
            case .low: return AgentPalette.green
            case .medium: return AgentPalette.warning
            case .elevated: return AgentPalette.indigo
            case .high: return AgentPalette.rose
            }
        }
    }

    struct ProjectMemoryItem: Identifiable {
        let id: String
        let title: String
        let path: String
        let detail: String
        let metadata: String
        let origin: String
        let status: String
        let group: ProjectMemoryGroup
        let risk: ProjectMemoryRisk
        let symbol: String
        let tint: Color
        let timestamp: Date?
        let sizeText: String?
        let isDirectory: Bool
        let isPreviewable: Bool
        let isEditable: Bool
        let isScreenshot: Bool
        let isVerification: Bool
        let isGenerated: Bool
        let isFailed: Bool
        let isImportant: Bool
        let isPinned: Bool
        let sourceToolRunIDString: String?
        let sourceTerminalCommandIDString: String?
        let sourceEventIDString: String?
        let shareURL: URL?

        var primaryPath: String {
            comparisonPaths?.destination ?? path
        }

        var comparisonPaths: (source: String, destination: String)? {
            let parts = path.components(separatedBy: " -> ")
            guard parts.count == 2 else { return nil }
            let source = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
            let destination = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !source.isEmpty, !destination.isEmpty else { return nil }
            return (source: source, destination: destination)
        }

        var timestampText: String {
            guard let timestamp else { return "No timestamp" }
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .abbreviated
            return formatter.localizedString(for: timestamp, relativeTo: Date())
        }

        var hasRelatedContext: Bool {
            sourceToolRunIDString != nil || sourceTerminalCommandIDString != nil || sourceEventIDString != nil
        }

        func matches(_ lens: FileWorkbenchLens) -> Bool {
            switch lens {
            case .all:
                return true
            case .recent:
                guard let timestamp else { return false }
                return timestamp > Date().addingTimeInterval(-86_400)
            case .important:
                return isImportant
            case .screenshots:
                return isScreenshot
            case .verification:
                return isVerification
            case .generated:
                return isGenerated
            case .failed:
                return isFailed
            case .pinned:
                return isPinned
            }
        }
    }

    struct ProjectMemorySection: Identifiable {
        let group: ProjectMemoryGroup
        let items: [ProjectMemoryItem]

        var id: String { group.rawValue }
    }

    struct FileComparisonDraft: Identifiable {
        let id = UUID()
        let title: String
        let sourcePath: String
        let destinationPath: String
        let summary: String
        let diffText: String
    }

    struct FileRelatedContextDraft: Identifiable {
        let id = UUID()
        let title: String
        let subtitle: String
        let detail: String
        let symbol: String
        let tint: Color
    }

    struct FileComparisonSheet: View {
        @Environment(\.dismiss) private var dismiss
        let draft: FileComparisonDraft

        var body: some View {
            ZStack {
                AgentBackground()

                VStack(alignment: .leading, spacing: 14) {
                    HeaderView(
                        title: "Changed-File Compare",
                        subtitle: draft.summary,
                        symbol: "arrow.left.arrow.right",
                        tint: AgentPalette.lilac
                    )

                    VStack(alignment: .leading, spacing: 8) {
                        comparePathRow(title: "Before", path: draft.sourcePath, tint: AgentPalette.secondaryText)
                        comparePathRow(title: "After", path: draft.destinationPath, tint: AgentPalette.cyan)
                    }

                    ScrollView {
                        Text(draft.diffText)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(AgentPalette.ink)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                    }
                    .background(AgentPalette.surface.opacity(0.72), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(AgentPalette.border.opacity(0.50), lineWidth: 0.7)
                    )

                    Button {
                        dismiss()
                    } label: {
                        Label("Close", systemImage: "xmark")
                            .frame(maxWidth: .infinity, minHeight: AgentDesign.minimumTouchTarget)
                    }
                    .buttonStyle(.bordered)
                }
                .padding()
            }
        }

        private func comparePathRow(title: String, path: String, tint: Color) -> some View {
            HStack(spacing: 8) {
                Text(title)
                    .font(.system(size: 8, weight: .black, design: AgentPalette.interfaceFontDesign))
                    .foregroundStyle(tint)
                    .textCase(.uppercase)
                    .frame(width: 44, alignment: .leading)
                Text(path)
                    .font(.system(size: 10, weight: .bold, design: AgentPalette.interfaceFontDesign))
                    .foregroundStyle(AgentPalette.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(.horizontal, 10)
            .frame(minHeight: 34)
            .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        }
    }

    struct FileRelatedContextSheet: View {
        @Environment(\.dismiss) private var dismiss
        let draft: FileRelatedContextDraft

        var body: some View {
            ZStack {
                AgentBackground()

                VStack(alignment: .leading, spacing: 14) {
                    HeaderView(
                        title: "Related Context",
                        subtitle: draft.subtitle,
                        symbol: draft.symbol,
                        tint: draft.tint
                    )

                    VStack(alignment: .leading, spacing: 8) {
                        Text(draft.title)
                            .font(.system(size: 14, weight: .black, design: AgentPalette.interfaceFontDesign))
                            .foregroundStyle(AgentPalette.ink)
                            .lineLimit(2)
                            .truncationMode(.middle)

                        ScrollView {
                            Text(draft.detail)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(AgentPalette.secondaryText)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(12)
                        }
                        .background(AgentPalette.surface.opacity(0.72), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }

                    Button {
                        dismiss()
                    } label: {
                        Label("Close", systemImage: "xmark")
                            .frame(maxWidth: .infinity, minHeight: AgentDesign.minimumTouchTarget)
                    }
                    .buttonStyle(.bordered)
                }
                .padding()
            }
        }
    }

    var selectedWorkbenchLens: FileWorkbenchLens {
        FileWorkbenchLens(rawValue: workbenchLensRawValue) ?? .all
    }

    var selectedInspectorMode: FileInspectorMode {
        FileInspectorMode(rawValue: inspectorModeRawValue) ?? .details
    }

    var projectMemoryItems: [ProjectMemoryItem] {
        cachedProjectMemoryItems
    }

    func evidenceBelongsToCurrentScope(_ evidenceProject: Project?) -> Bool {
        HistoryWorkspacePresentation.evidenceBelongsToScope(
            evidenceProjectID: evidenceProject?.id,
            scopeProjectID: scopeProject?.id
        )
    }

    func rebuildProjectMemoryCache(fileRows: [FileRowData]? = nil) {
        let artifactItems = scopedArtifactRecords
            .filter { evidenceBelongsToCurrentScope($0.project) }
            .map(memoryItem(for:))
        let changeItems = scopedFileChangeRecords
            .filter { evidenceBelongsToCurrentScope($0.project) }
            .map(memoryItem(for:))
        let fileItems = (fileRows ?? items).map(memoryItem(for:))
        cachedProjectMemoryItems = (artifactItems + changeItems + fileItems)
            .sorted(by: compareMemoryItems)
    }

    /// `@Query` updates the evidence rows without involving the active
    /// project, while this small value snapshot tells the derived-memory cache
    /// when it must be rebuilt. Keeping it to IDs and durable timestamps avoids
    /// a second large transformation in `body`.
    var artifactEvidenceRevision: [String] {
        scopedArtifactRecords.map { record in
            "\(record.id.uuidString):\(record.updatedAt.timeIntervalSinceReferenceDate)"
        }
    }

    var fileChangeEvidenceRevision: [String] {
        scopedFileChangeRecords.map { record in
            "\(record.id.uuidString):\(record.createdAt.timeIntervalSinceReferenceDate)"
        }
    }

    var filteredProjectMemoryItems: [ProjectMemoryItem] {
        projectMemoryItems.filter { $0.matches(selectedWorkbenchLens) }
    }

    var selectedMemoryItem: ProjectMemoryItem? {
        guard !selectedMemoryItemID.isEmpty else { return nil }
        return projectMemoryItems.first(where: { $0.id == selectedMemoryItemID })
    }

    var projectMemorySections: [ProjectMemorySection] {
        let grouped = Dictionary(grouping: filteredProjectMemoryItems, by: \.group)
        return grouped
            .map { ProjectMemorySection(group: $0.key, items: $0.value.sorted(by: compareMemoryItems)) }
            .sorted {
                if $0.group.priority != $1.group.priority { return $0.group.priority < $1.group.priority }
                return $0.group.title < $1.group.title
            }
    }

    var artifactGalleryItems: [ProjectMemoryItem] {
        projectMemoryItems
            .filter { item in
                item.group == .artifacts || item.group == .screenshots || item.isGenerated || item.isVerification
            }
            .prefix(12)
            .map { $0 }
    }

    var memoryIsStale: Bool {
        guard let newest = projectMemoryItems.compactMap(\.timestamp).max() else { return false }
        return newest < Date().addingTimeInterval(-86_400)
    }

    var memoryPreferencePrefix: String {
        "novaforge.files.memory.\(scopeProject?.id.uuidString ?? "general-\(scopeConversationID.uuidString)")"
    }

    var changedFileCount: Int {
        projectMemoryItems.filter { $0.group == .changed }.count
    }

    var artifactCount: Int {
        projectMemoryItems.filter { $0.group == .artifacts || $0.isGenerated }.count
    }

    var verificationCount: Int {
        projectMemoryItems.filter { $0.isVerification || $0.isScreenshot }.count
    }

    var riskCount: Int {
        projectMemoryItems.filter { $0.risk == .elevated || $0.risk == .high }.count
    }

    var recentTerminalRecords: [TerminalCommandRecord] {
        scopedTerminalCommandRecords
            .sorted {
                if $0.completedAt != $1.completedAt { return $0.completedAt > $1.completedAt }
                return $0.id.uuidString < $1.id.uuidString
            }
            .prefix(3)
            .map { $0 }
    }

    var terminalProofCount: Int {
        scopedTerminalCommandRecords.count
    }

    var failedTerminalProofCount: Int {
        scopedTerminalCommandRecords.filter { $0.status == .failed }.count
    }

    var primaryWorkbenchItem: ProjectMemoryItem? {
        artifactGalleryItems.first ??
            projectMemoryItems.first(where: { $0.group == .changed }) ??
            projectMemoryItems.first
    }

    var recentChangeItems: [ProjectMemoryItem] {
        projectMemoryItems
            .filter { $0.group == .changed }
            .prefix(3)
            .map { $0 }
    }

    func memoryItem(for row: FileRowData) -> ProjectMemoryItem {
        let item = row.item
        let path = item.relativePath
        let artifact = WorkspaceArtifact(path: path)
        let relatedChange = scopedFileChangeRecords.first { change in
            change.path == path || change.path.components(separatedBy: " -> ").contains(path)
        }
        let isScreenshot = isScreenshotPath(path)
        let isVerification = isVerificationPath(path) || artifact.isReportArtifact || artifact.isLogArtifact
        let isGenerated = isGeneratedPath(path)
        let group = memoryGroup(
            path: path,
            isDirectory: item.isDirectory,
            isArtifact: scopedArtifactRecords.contains { $0.path == path },
            isChanged: relatedChange != nil,
            isScreenshot: isScreenshot,
            isVerification: isVerification
        )
        let failed = isFailurePath(path)
        let previewable = !item.isDirectory && canPreviewPath(path)
        let risk = riskFor(path: path, action: relatedChange?.action, isFailed: failed, group: group)
        return ProjectMemoryItem(
            id: "file:\(path)",
            title: item.name,
            path: path,
            detail: relatedChange.map { "\($0.action) in project memory" } ?? fileDetail(for: artifact, item: item),
            metadata: "\(row.kindText) · \(row.modifiedText)",
            origin: Self.provenanceLabel(
                base: currentPath.isEmpty ? "Workspace root" : "Workspace folder",
                toolRunID: relatedChange?.sourceToolRunIDString,
                terminalCommandID: relatedChange?.sourceTerminalCommandIDString,
                eventID: relatedChange?.sourceEventIDString
            ),
            status: row.isRecent ? "Fresh" : group.title,
            group: group,
            risk: risk,
            symbol: row.visualKind.symbolName,
            tint: row.visualKind.tint,
            timestamp: item.modifiedAt,
            sizeText: item.isDirectory ? nil : row.kindText,
            isDirectory: item.isDirectory,
            isPreviewable: previewable,
            isEditable: !item.isDirectory && !previewable,
            isScreenshot: isScreenshot,
            isVerification: isVerification,
            isGenerated: isGenerated,
            isFailed: failed,
            isImportant: importantMemoryPaths.contains(path),
            isPinned: pinnedMemoryPaths.contains(path),
            sourceToolRunIDString: relatedChange?.sourceToolRunIDString,
            sourceTerminalCommandIDString: relatedChange?.sourceTerminalCommandIDString,
            sourceEventIDString: relatedChange?.sourceEventIDString,
            shareURL: workspaceShareURL(for: path)
        )
    }

    func memoryItem(for artifactRecord: ProjectArtifact) -> ProjectMemoryItem {
        let artifact = WorkspaceArtifact(path: artifactRecord.path)
        let path = artifactRecord.path
        let isScreenshot = isScreenshotPath(path) || artifact.isImageArtifact
        let isVerification = isVerificationPath(path) || artifact.isReportArtifact || artifact.isLogArtifact || artifact.isPDFArtifact
        let failed = artifactRecord.status == .failed || artifactRecord.exportStatus == .failed || isFailurePath(path)
        let group = memoryGroup(
            path: path,
            isDirectory: false,
            isArtifact: true,
            isChanged: false,
            isScreenshot: isScreenshot,
            isVerification: isVerification
        )
        let detail = artifactRecord.descriptionText?.trimmingCharacters(in: .whitespacesAndNewlines)
        let status = failed ? "Failed" : artifactRecord.status.rawValue.capitalized
        return ProjectMemoryItem(
            id: "artifact:\(path)",
            title: artifactRecord.title.isEmpty ? artifact.title : artifactRecord.title,
            path: path,
            detail: detail?.isEmpty == false ? detail! : "\(artifact.artifactType.displayName) output captured for this project.",
            metadata: "\(artifact.artifactType.displayName) · \(dateText(artifactRecord.updatedAt))",
            origin: Self.provenanceLabel(
                base: artifactRecord.sourceToolRunIDString == nil ? "Project artifact" : "Tool run artifact",
                toolRunID: artifactRecord.sourceToolRunIDString,
                terminalCommandID: nil,
                eventID: nil
            ),
            status: status,
            group: group,
            risk: riskFor(path: path, action: status, isFailed: failed, group: group),
            symbol: artifact.symbol,
            tint: failed ? AgentPalette.rose : (artifact.isWebPage || artifact.isSwiftGameArtifact || isScreenshot ? AgentPalette.green : AgentPalette.cyan),
            timestamp: artifactRecord.updatedAt,
            sizeText: fileSizeText(for: path),
            isDirectory: false,
            isPreviewable: artifact.isReadablePreviewArtifact,
            isEditable: !artifact.isReadablePreviewArtifact,
            isScreenshot: isScreenshot,
            isVerification: isVerification,
            isGenerated: true,
            isFailed: failed,
            isImportant: importantMemoryPaths.contains(path),
            isPinned: pinnedMemoryPaths.contains(path),
            sourceToolRunIDString: artifactRecord.sourceToolRunIDString,
            sourceTerminalCommandIDString: nil,
            sourceEventIDString: nil,
            shareURL: workspaceShareURL(for: path)
        )
    }

    func memoryItem(for change: ProjectFileChange) -> ProjectMemoryItem {
        let path = change.path
        let primaryPath = comparisonDestination(in: path)?.destination ?? path
        let artifact = WorkspaceArtifact(path: primaryPath)
        let failed = isFailurePath(path) || change.action.localizedCaseInsensitiveContains("failed")
        let isScreenshot = isScreenshotPath(primaryPath) || artifact.isImageArtifact
        let isVerification = isVerificationPath(primaryPath) || artifact.isReportArtifact || artifact.isLogArtifact
        let actionIsGenerated = change.action.localizedCaseInsensitiveContains("created") ||
            change.action.localizedCaseInsensitiveContains("generated") ||
            change.action.localizedCaseInsensitiveContains("duplicated")
        return ProjectMemoryItem(
            id: "change:\(change.id.uuidString)",
            title: change.action,
            path: path,
            detail: reviewSummary(for: change.action, path: path),
            metadata: "\(dateText(change.createdAt)) · \(primaryPath)",
            origin: Self.provenanceLabel(
                base: change.sourceToolRunIDString == nil ? "Workspace change" : "Tool run change",
                toolRunID: change.sourceToolRunIDString,
                terminalCommandID: change.sourceTerminalCommandIDString,
                eventID: change.sourceEventIDString
            ),
            status: changeStatus(for: change.action),
            group: .changed,
            risk: riskFor(path: primaryPath, action: change.action, isFailed: failed, group: .changed),
            symbol: artifact.symbol,
            tint: failed ? AgentPalette.rose : AgentPalette.cyan,
            timestamp: change.createdAt,
            sizeText: fileSizeText(for: primaryPath),
            isDirectory: false,
            isPreviewable: canPreviewPath(primaryPath),
            isEditable: !canPreviewPath(primaryPath),
            isScreenshot: isScreenshot,
            isVerification: isVerification,
            isGenerated: actionIsGenerated,
            isFailed: failed,
            isImportant: importantMemoryPaths.contains(primaryPath) || importantMemoryPaths.contains(path),
            isPinned: pinnedMemoryPaths.contains(primaryPath) || pinnedMemoryPaths.contains(path),
            sourceToolRunIDString: change.sourceToolRunIDString,
            sourceTerminalCommandIDString: change.sourceTerminalCommandIDString,
            sourceEventIDString: change.sourceEventIDString,
            shareURL: workspaceShareURL(for: primaryPath)
        )
    }

    func compareMemoryItems(_ lhs: ProjectMemoryItem, _ rhs: ProjectMemoryItem) -> Bool {
        if lhs.isPinned != rhs.isPinned { return lhs.isPinned && !rhs.isPinned }
        if lhs.isImportant != rhs.isImportant { return lhs.isImportant && !rhs.isImportant }
        if lhs.group.priority != rhs.group.priority { return lhs.group.priority < rhs.group.priority }
        switch (lhs.timestamp, rhs.timestamp) {
        case let (lhsDate?, rhsDate?):
            if lhsDate != rhsDate { return lhsDate > rhsDate }
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        case (nil, nil):
            break
        }
        return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
    }

    func memoryGroup(
        path: String,
        isDirectory: Bool,
        isArtifact: Bool,
        isChanged: Bool,
        isScreenshot: Bool,
        isVerification: Bool
    ) -> ProjectMemoryGroup {
        if isChanged { return .changed }
        if isScreenshot { return .screenshots }
        if isVerification { return .verification }
        if isArtifact { return .artifacts }
        if isDirectory { return .folders }
        let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
        if ["md", "markdown", "txt", "pdf", "csv"].contains(ext) || path.localizedCaseInsensitiveContains("report") {
            return .documents
        }
        if ["sh", "bash", "zsh"].contains(ext) || path.localizedCaseInsensitiveContains("script") {
            return .scripts
        }
        if ["swift", "js", "css", "py", "json", "yaml", "yml", "xml", "plist"].contains(ext) {
            return .source
        }
        return .files
    }

    func riskFor(path: String, action: String?, isFailed: Bool, group: ProjectMemoryGroup) -> ProjectMemoryRisk {
        if isFailed { return .high }
        let lower = path.lowercased()
        if lower.contains("agentpad/") || lower.contains("models") || lower.contains("services") || lower.contains("runtime") || lower.contains("settings") {
            return .elevated
        }
        if group == .scripts || ["swift", "js", "py", "sh"].contains(URL(fileURLWithPath: path).pathExtension.lowercased()) {
            return .medium
        }
        if action?.localizedCaseInsensitiveContains("deleted") == true {
            return .elevated
        }
        return .low
    }

    func isScreenshotPath(_ path: String) -> Bool {
        let lower = path.lowercased()
        return lower.contains("screenshot") || lower.contains("screen-shot") || lower.contains("snapshots/") || ["png", "jpg", "jpeg", "webp"].contains(URL(fileURLWithPath: path).pathExtension.lowercased())
    }

    func isVerificationPath(_ path: String) -> Bool {
        let lower = path.lowercased()
        return lower.contains("proof") || lower.contains("verify") || lower.contains("verification") || lower.contains("qa/") || lower.contains("test") || lower.contains("report") || lower.contains("log")
    }

    func isGeneratedPath(_ path: String) -> Bool {
        let lower = path.lowercased()
        return lower.contains("generated") || lower.contains("artifact") || lower.contains("output") || lower.contains("export")
    }

    func isFailurePath(_ path: String) -> Bool {
        let lower = path.lowercased()
        return lower.contains("failed") || lower.contains("failure") || lower.contains("error")
    }

    func fileDetail(for artifact: WorkspaceArtifact, item: FileItem) -> String {
        if item.isDirectory { return "Workspace folder with current project material." }
        if artifact.isImageArtifact { return artifact.path.lowercased().contains("screenshot") ? "Visual verification evidence." : "Image output in the workspace." }
        if artifact.isMarkdownArtifact || artifact.isReportArtifact { return "Readable report or notes output." }
        if artifact.isLogArtifact { return "Log evidence captured in the workspace." }
        if artifact.isWebPage { return "Previewable HTML artifact." }
        if artifact.artifactType == .source { return "Source file available for review." }
        return "Workspace file available for inspection."
    }

    func reviewSummary(for action: String, path: String) -> String {
        if let comparison = comparisonDestination(in: path) {
            return "\(action) from \(comparison.source) to \(comparison.destination). Compare both versions before relying on the output."
        }
        if action.localizedCaseInsensitiveContains("deleted") {
            return "Deletion record. Confirm the removed path was intentional."
        }
        if action.localizedCaseInsensitiveContains("saved") {
            return "Saved file. Review the current contents and nearby evidence."
        }
        return "Recorded project change. Inspect the file and related proof before continuing."
    }

    func changeStatus(for action: String) -> String {
        if action.localizedCaseInsensitiveContains("deleted") { return "Deleted" }
        if action.localizedCaseInsensitiveContains("created") { return "Created" }
        if action.localizedCaseInsensitiveContains("duplicated") { return "Duplicated" }
        if action.localizedCaseInsensitiveContains("saved") { return "Saved" }
        return "Changed"
    }

    func comparisonDestination(in path: String) -> (source: String, destination: String)? {
        let parts = path.components(separatedBy: " -> ")
        guard parts.count == 2 else { return nil }
        let source = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
        let destination = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty, !destination.isEmpty else { return nil }
        return (source: source, destination: destination)
    }

    func fileSizeText(for path: String) -> String? {
        guard let url = try? runtime.workspace.resolve(path),
              let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize else {
            return nil
        }
        return Self.byteCountString(Int64(size))
    }

    func dateText(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    func workspaceShareURL(for path: String) -> URL? {
        guard let url = try? runtime.workspace.resolve(path),
              FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        return url
    }

    static func provenanceReference(
        toolRunID: String?,
        terminalCommandID: String?,
        eventID: String?
    ) -> String {
        HistoryWorkspacePresentation.provenanceReference(
            toolRunID: toolRunID,
            terminalCommandID: terminalCommandID,
            eventID: eventID
        )
    }

    static func provenanceLabel(
        base: String,
        toolRunID: String?,
        terminalCommandID: String?,
        eventID: String?
    ) -> String {
        HistoryWorkspacePresentation.provenanceLabel(
            base: base,
            toolRunID: toolRunID,
            terminalCommandID: terminalCommandID,
            eventID: eventID
        )
    }

    static func workspaceScopeLine(projectName: String, workspaceName: String) -> String {
        HistoryWorkspacePresentation.workspaceScopeLine(
            projectName: projectName,
            workspaceName: workspaceName
        )
    }

    func workspaceProvenanceHandoff(_ item: ProjectMemoryItem) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .font(.system(size: 12, weight: .black))
                    .foregroundStyle(AgentPalette.cyan)
                    .frame(width: 30, height: 30)
                    .background(AgentPalette.cyan.opacity(0.10), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    Text("Handoff & provenance")
                        .font(.system(size: 11.5, weight: .black, design: AgentPalette.interfaceFontDesign))
                        .foregroundStyle(AgentPalette.ink)
                    Text(Self.workspaceScopeLine(projectName: scopeTitle, workspaceName: runtime.workspace.workspaceName))
                        .font(.system(size: 9, weight: .semibold, design: AgentPalette.interfaceFontDesign))
                        .foregroundStyle(AgentPalette.secondaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text("\(item.origin) · \(item.primaryPath)")
                        .font(.system(size: 8.5, weight: .semibold, design: AgentPalette.interfaceFontDesign))
                        .foregroundStyle(AgentPalette.tertiaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(spacing: 8) {
                Button {
                    openMemoryItem(item)
                } label: {
                    handoffActionLabel(
                        title: primaryActionTitle(for: item),
                        symbol: primaryActionSymbol(for: item),
                        tint: item.tint
                    )
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("filesHandoffOpen")

                if let shareURL = item.shareURL, !item.isDirectory {
                    ShareLink(item: shareURL) {
                        handoffActionLabel(title: "Share", symbol: "square.and.arrow.up", tint: AgentPalette.lilac)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("filesHandoffShare")
                }

                Button {
                    copyMemoryPath(item)
                } label: {
                    handoffActionLabel(title: "Copy path", symbol: "doc.on.doc", tint: AgentPalette.cyan)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("filesHandoffCopyPath")
            }
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AgentPalette.row.opacity(0.58), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(AgentPalette.cyan.opacity(0.16), lineWidth: 0.7)
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("filesProvenanceHandoff")
    }

    func handoffActionLabel(title: String, symbol: String, tint: Color) -> some View {
        Label(title, systemImage: symbol)
            .font(.system(size: 9.5, weight: .black, design: AgentPalette.interfaceFontDesign))
            .foregroundStyle(AgentPalette.ink)
            .lineLimit(1)
            .minimumScaleFactor(0.76)
            .frame(maxWidth: .infinity, minHeight: AgentDesign.minimumTouchTarget)
            .agentControlSurface(radius: 11, tint: tint.opacity(0.10), selected: true)
    }

    /// Keep the dense explorer hierarchy behind an opaque result boundary so
    /// the lifecycle/presentation modifier chain below does not force Swift's
    /// type checker to solve the entire screen as one expression.
    @ViewBuilder
    var filesRootSurface: some View {
        ZStack {
            VStack(spacing: 12) {
                filesScreenHeader
                    .padding(.horizontal)
                    .padding(.top, 14)

                if runtime.shouldShowWorkspaceStatusStrip {
                    WorkspaceStatusStrip(runtime: runtime, openChat: openChat)
                        .padding(.horizontal)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }

                if !currentPath.isEmpty {
                    breadcrumbs
                }
                actionBar
                    .padding(.horizontal)

                ScrollView(showsIndicators: false) {
                    LazyVStack(spacing: 14) {
                        if let fileLoadError {
                            FilesLoadErrorState(
                                path: currentPath,
                                message: fileLoadError,
                                retry: reload,
                                goHome: {
                                    currentPath = ""
                                    reload()
                                }
                            )
                        } else if items.isEmpty {
                            FilesEmptyState(
                                create: {
                                    showingCreate = true
                                },
                                openChat: openChat
                            )
                        } else {
                            fileBrowserSectionHeader
                                .padding(.horizontal)

                            if isGridLayout {
                                gridLayout
                            } else {
                                listLayout
                            }
                        }

                        evidenceSection
                            .padding(.horizontal)
                    }
                }
                .scrollContentBackground(.hidden)
                .agentDockEdgeFade()
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    BottomDockContentShield(height: tabBarClearance)
                }
            }
            
        if isExporting {
                ZStack {
                    AgentPalette.ice.opacity(0.55)
                        .ignoresSafeArea()
                    
                    VStack(spacing: 16) {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .tint(AgentPalette.lilac)
                            .scaleEffect(1.5)
                        
                        Text("Preparing ZIP...")
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(AgentPalette.ink)
                    }
                    .padding(24)
                    .agentGlass(radius: 20, tint: AgentPalette.lilac.opacity(0.14))
                }
                .transition(.opacity.combined(with: .scale(scale: 0.95)))
            }

        if let fileActionStatus {
                ZStack {
                    AgentPalette.ice.opacity(0.30)
                        .ignoresSafeArea()

                    HStack(spacing: 12) {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .tint(AgentPalette.cyan)
                        Text(fileActionStatus)
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(AgentPalette.ink)
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 14)
                    .agentSurface(radius: 18, tint: AgentPalette.cyan.opacity(0.12))
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(fileActionStatus)
                    .accessibilityIdentifier("filesActionBusy")
                }
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
            }

            if let transientNotice {
                VStack {
                    Spacer()
                    Text(transientNotice)
                        .font(.system(size: 11, weight: .black, design: AgentPalette.interfaceFontDesign))
                        .foregroundStyle(AgentPalette.ink)
                        .padding(.horizontal, 14)
                        .frame(minHeight: 38)
                        .agentControlSurface(radius: 14, tint: AgentPalette.green.opacity(0.14), selected: true)
                        .padding(.bottom, tabBarClearance + 10)
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .accessibilityIdentifier("filesTransientNotice")
            }
        }
    }

    private var filesLifecycleSurface: some View {
        filesRootSurface
        .task {
            loadMemoryFlags()
            rebuildProjectMemoryCache()
            seedFileStressIfNeeded()
            reload()
            reloadWorkspaces()
            openDebugArtifactPreviewIfRequested()
            openFilesSurfaceDemosIfRequested()
        }
        .onChange(of: scopeConversationID) { _, _ in
            selectedMemoryItemID = ""
            loadMemoryFlags()
            rebuildProjectMemoryCache()
        }
        .onChange(of: scopeProject?.updatedAt) { _, _ in
            rebuildProjectMemoryCache()
        }
        .onChange(of: artifactEvidenceRevision) { _, _ in
            rebuildProjectMemoryCache()
        }
        .onChange(of: fileChangeEvidenceRevision) { _, _ in
            rebuildProjectMemoryCache()
        }
        .onChange(of: runtime.workspace.workspaceName) { _, _ in
            currentPath = ""
            reload()
            reloadWorkspaces()
        }
        .onChange(of: importantMemoryPaths) { _, _ in
            rebuildProjectMemoryCache()
        }
        .onChange(of: pinnedMemoryPaths) { _, _ in
            rebuildProjectMemoryCache()
        }
    }

    private var filesInspectorSurface: some View {
        filesLifecycleSurface
        .sheet(item: $editingTarget) { target in
            CodeEditorView(
                fileName: target.item.name,
                relativePath: target.item.relativePath,
                workspace: runtime.workspace,
                projectID: project.id,
                conversationID: scopeConversationID,
                initialLineNumber: target.focusedLineNumber,
                onSave: {
                    runtime.noteWorkspaceChanged()
                    ProjectEventRecorder.recordFileChange(
                        project: scopeProject,
                        action: "Saved file",
                        path: target.item.relativePath,
                        context: modelContext
                    )
                    saveFileEvidence(
                        failureMessage: "Saved \(target.item.name), but NovaForge could not save the project proof record"
                    )
                    reload()
                }
            )
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
        .sheet(isPresented: $showingSearch) {
            searchSheet
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(item: $comparisonDraft) { draft in
            FileComparisonSheet(draft: draft)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(
            isPresented: Binding(
                get: { selectedMemoryItem != nil },
                set: { if !$0 { selectedMemoryItemID = "" } }
            )
        ) {
            if let selectedMemoryItem {
                memoryInspectorSheet(for: selectedMemoryItem)
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            }
        }
        .sheet(item: $relatedContextDraft) { draft in
            FileRelatedContextSheet(draft: draft)
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
        }
    }

    private var filesSearchLifecycleSurface: some View {
        filesInspectorSurface
        .onChange(of: showingSearch) { _, isShowing in
            if !isShowing {
                cancelSearch()
                if let target = pendingSearchOpenTarget {
                    pendingSearchOpenTarget = nil
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        editingTarget = target
                    }
                }
            } else {
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(220))
                    guard showingSearch else { return }
                    searchFocused = true
                }
            }
        }
        .onDisappear {
            cancelSearch()
            reloadTask?.cancel()
            fileActionTask?.cancel()
            pendingSearchOpenTarget = nil
            reloadTask = nil
            fileActionTask = nil
            fileActionStatus = nil
        }
    }

    private var filesCreationAndAlertSurface: some View {
        filesSearchLifecycleSurface
        .sheet(isPresented: $showingCreate) {
            CreateFileSheet(
                currentPath: currentPath,
                createMutation: { path, isDirectory in
                    let operationID = UUID()
                    if isDirectory {
                        _ = try await performFilesMutation(
                            operationID: operationID,
                            operation: FilesCanonicalMutationOperation.makeDirectory(
                                PathArguments(path: path)
                            )
                        )
                    } else {
                        _ = try await performFilesMutation(
                            operationID: operationID,
                            operation: FilesPolicyMutationOperation.createFile(
                                CreateFileMutationArguments(path: path)
                            )
                        )
                    }
                },
                onCreated: { path, isDirectory in
                    runtime.noteWorkspaceChanged()
                    ProjectEventRecorder.recordFileChange(
                        project: scopeProject,
                        action: isDirectory ? "Created folder" : "Created file",
                        path: path,
                        context: modelContext
                    )
                    saveFileEvidence(
                        failureMessage: "Created \(isDirectory ? "folder" : "file") \(path), but NovaForge could not save the project proof record"
                    )
                    reload()
                }
            )
            .presentationDetents([.height(320)])
            .presentationDragIndicator(.visible)
        }
        .alert("Create Workspace", isPresented: $showingCreateWorkspace) {
            TextField("Workspace Name", text: $newWorkspaceName)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("Create") {
                createWorkspace()
            }
            Button("Cancel", role: .cancel) {}
        }
        .alert(
            "File Action Failed",
            isPresented: Binding(
                get: { fileActionError != nil },
                set: { if !$0 { fileActionError = nil } }
            )
        ) {
            Button("OK", role: .cancel) { fileActionError = nil }
        } message: {
            Text(fileActionError ?? "NovaForge could not complete that file action.")
        }
        .alert(
            "Workspace Not Saved",
            isPresented: Binding(
                get: { workspaceSaveError != nil },
                set: { if !$0 { workspaceSaveError = nil } }
            )
        ) {
            Button("OK", role: .cancel) { workspaceSaveError = nil }
        } message: {
            Text(workspaceSaveError ?? "NovaForge could not save the workspace selection, so it kept the current workspace open.")
        }
        .confirmationDialog(
            pendingDeleteItem.map { "Delete \($0.name)?" } ?? "Delete item?",
            isPresented: Binding(
                get: { pendingDeleteItem != nil },
                set: { if !$0 { pendingDeleteItem = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let item = pendingDeleteItem {
                Button(item.isDirectory ? "Delete Folder" : "Delete File", role: .destructive) {
                    pendingDeleteItem = nil
                    deleteFile(item)
                }
                .accessibilityIdentifier(item.isDirectory ? "confirmDeleteFolderButton" : "confirmDeleteFileButton")
            }
            Button("Cancel", role: .cancel) {
                pendingDeleteItem = nil
            }
        } message: {
            if let item = pendingDeleteItem {
                Text(deleteConfirmationDetail(for: item))
            }
        }
    }

    var body: some View {
        filesCreationAndAlertSurface
        .scrollDismissesKeyboard(.interactively)
        #if DEBUG
        // Stress fixtures now travel through the same policy and receipt path
        // as production mutations. Expose completion—not partial filesystem
        // contents—so UI tests never race the final durable writes/reload.
        .overlay(alignment: .topLeading) {
            if debugFileFixtureIsDurable {
                Color.clear
                    .frame(width: 1, height: 1)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("File fixture ready")
                    .accessibilityIdentifier("filesStressFixtureReady")
                    .allowsHitTesting(false)
            }
        }
        #endif
    }

    #if DEBUG
    private var debugFileFixtureIsDurable: Bool {
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--stress-files") {
            return (try? runtime.workspace.read(".novaforge-file-stress")) == "v1"
                && (try? runtime.workspace.read("Sources/Generated/Module12.swift"))?
                    .contains("Fixture symbol 12") == true
        }
        return arguments.contains("--files-actions-test")
            && isFileStressFixtureReady
    }
    #endif

    /// Facelift screen opener: hero title with workspace strapline, live
    /// file telemetry in the status line, and one quiet mission readout.
    /// Replaces the old banner + explorer card + stat-chip stack.
    var filesScreenHeader: some View {
        NovaScreenHeader(
            kicker: scopeTitle,
            title: "Workspace",
            subtitle: filesHeaderStatusLine,
            symbol: "folder.fill",
            tint: AgentPalette.cyan,
            isActive: runtime.isWorking
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("filesProjectOverview")
    }

    var filesHeaderStatusLine: String {
        currentPath.isEmpty
            ? "Files, artifacts, and proof for this mission."
            : "Browsing \(currentPath)"
    }

    func reload() {
        AgentPerformance.event("Files Reload Requested")
        let path = currentPath
        let workspace = runtime.workspace
        let cutoff = Date().addingTimeInterval(-300)
        reloadTask?.cancel()
        reloadTask = Task.detached(priority: .userInitiated) {
            let signpostID = AgentPerformance.begin("Files Reload")
            defer {
                AgentPerformance.end("Files Reload", id: signpostID)
            }
            do {
                let loadedItems = try workspace.list(path)
                var stats = loadedItems.reduce(into: FileStats()) { stats, item in
                    if item.isDirectory {
                        stats.folderCount += 1
                    } else {
                        stats.fileCount += 1
                        if WorkspaceArtifact(path: item.relativePath).isReadablePreviewArtifact {
                            stats.previewableCount += 1
                        }
                    }
                    stats.totalBytes += item.byteCount
                    if let modifiedAt = item.modifiedAt {
                        if modifiedAt > cutoff {
                            stats.recentCount += 1
                        }
                        if stats.newestDate == nil || modifiedAt > (stats.newestDate ?? .distantPast) {
                            stats.newestDate = modifiedAt
                            stats.newestName = item.name
                        }
                    }
                }
                stats.totalBytesText = Self.byteCountString(stats.totalBytes)
                let rows = loadedItems.map { FileRowData(item: $0, recentCutoff: cutoff) }
                AgentPerformance.value("Files Loaded Rows", Double(rows.count))
                AgentPerformance.value("Files Loaded Bytes", Double(stats.totalBytes))
                await MainActor.run {
                    guard !Task.isCancelled, currentPath == path else { return }
                    recentCutoff = cutoff
                    items = rows
                    cachedStats = stats
                    rebuildProjectMemoryCache(fileRows: rows)
                    fileLoadError = nil
                    reloadTask = nil
                }
            } catch is CancellationError {
                await MainActor.run {
                    guard currentPath == path else { return }
                    reloadTask = nil
                }
            } catch {
                let message = error.localizedDescription
                await MainActor.run {
                    guard !Task.isCancelled, currentPath == path else { return }
                    items = []
                    cachedStats = FileStats()
                    rebuildProjectMemoryCache(fileRows: [])
                    fileLoadError = message
                    reloadTask = nil
                }
            }
        }
    }

    func reloadWorkspaces() {
        workspaces = SandboxWorkspace.listWorkspaces()
    }

    func switchWorkspace(to name: String, clearDraftOnSuccess: Bool = false) {
        let safeName = SandboxWorkspace.sanitizedWorkspaceName(name)
        guard !isWorkspaceRoutingLocked() else {
            workspaceSaveError = "Finish or stop the active mission before switching workspaces. NovaForge kept the current workspace unchanged."
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
            return
        }
        guard workspaceSwitchTask == nil else {
            workspaceSaveError = "NovaForge is already preparing another workspace. The current workspace is unchanged."
            return
        }

        workspaceSaveError = nil
        workspaceSwitchTask = Task { @MainActor in
            defer { workspaceSwitchTask = nil }
            do {
                let switched = try await runtime.switchWorkspace(
                    to: safeName,
                    context: modelContext
                ) {
                    if project.workspaceName != safeName {
                        ProjectEventRecorder.record(
                            project: project,
                            kind: .workspaceChanged,
                            title: "Workspace changed",
                            detail: safeName,
                            severity: .info,
                            sourceType: .workspace,
                            context: modelContext
                        )
                    }
                    try FilesWorkspacePersistence.persistProjectWorkspaceSelection(
                        safeName,
                        project: project,
                        settings: settings,
                        save: { try modelContext.save() }
                    )
                }
                guard switched else {
                    workspaceSaveError = "NovaForge could not switch workspaces while work is active. The current workspace is unchanged."
                    UINotificationFeedbackGenerator().notificationOccurred(.warning)
                    return
                }
                if clearDraftOnSuccess {
                    newWorkspaceName = ""
                }
                currentPath = ""
                reload()
                reloadWorkspaces()
            } catch is CancellationError {
                modelContext.rollback()
            } catch {
                modelContext.rollback()
                workspaceSaveError = "Could not switch to \(safeName): \(error.localizedDescription)"
                UINotificationFeedbackGenerator().notificationOccurred(.error)
            }
        }
    }

    func createWorkspace() {
        let name = SandboxWorkspace.sanitizedWorkspaceName(newWorkspaceName)
        guard !name.isEmpty else { return }
        switchWorkspace(to: name, clearDraftOnSuccess: true)
    }

    func open(_ item: FileItem) {
        if item.isDirectory {
            withAnimation(reduceMotion ? nil : .smooth(duration: 0.3)) {
                currentPath = item.relativePath
                reload()
            }
        } else {
            if canPreview(item) {
                preview(item)
            } else {
                editingTarget = FileEditTarget(item: item)
            }
        }
    }

    func preview(_ item: FileItem) {
        previewArtifactPath(item.relativePath, displayName: item.name)
    }

    func editFile(_ item: FileItem) {
        guard !item.isDirectory else { return }
        editingTarget = FileEditTarget(item: item)
    }

    func previewArtifactPath(_ path: String, displayName: String? = nil) {
        let artifact = WorkspaceArtifact(path: path)
        // A persisted inspector selection can still be resolving as Workspace
        // appears. Clear that sheet route before opening the fullscreen preview so
        // SwiftUI never has two presentation requests racing for the same tap.
        selectedMemoryItemID = ""
        ProjectEventRecorder.noteArtifactPreview(
            artifact,
            project: scopeProject,
            context: modelContext
        )
        saveFileEvidence(
            failureMessage: "Opened preview for \(displayName ?? readableEvidencePath(path)), but NovaForge could not save the artifact proof record"
        )
        previewArtifact = artifact
    }

    func openWorkspaceEvidencePath(_ path: String) {
        if canPreviewPath(path) {
            previewArtifactPath(path)
            return
        }

        do {
            let url = try runtime.workspace.resolve(path)
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey])
            let isDirectory = values.isDirectory ?? false
            let item = FileItem(
                name: url.lastPathComponent,
                relativePath: path,
                isDirectory: isDirectory,
                byteCount: Int64(values.fileSize ?? 0),
                modifiedAt: values.contentModificationDate
            )
            if isDirectory {
                currentPath = path
                reload()
            } else {
                editingTarget = FileEditTarget(item: item)
            }
        } catch {
            let parent = parentPath(for: path)
            currentPath = parent
            reload()
            fileActionError = "Could not open \(readableEvidencePath(path)): \(error.localizedDescription)"
        }
    }

    func openDebugArtifactPreviewIfRequested() {
        #if DEBUG || targetEnvironment(simulator)
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains("--workbench-open-artifact-preview"),
              !didOpenDebugArtifactPreview else { return }
        didOpenDebugArtifactPreview = true
        Task { @MainActor in
            let artifactPath: String
            if arguments.contains("--project-spine-e2e-demo") {
                artifactPath = "workflow-spine-proof.html"
            } else if arguments.contains("--project-proof-demo") {
                artifactPath = "project-os-proof.html"
            } else {
                artifactPath = "slither-arena.html"
            }
            for _ in 0..<10 {
                if let url = try? runtime.workspace.resolve(artifactPath),
                   FileManager.default.fileExists(atPath: url.path) {
                    ProjectEventRecorder.noteArtifactPreview(
                        WorkspaceArtifact(path: artifactPath),
                        project: scopeProject,
                        context: modelContext
                    )
                    previewArtifact = WorkspaceArtifact(path: artifactPath)
                    return
                }
                try? await Task.sleep(for: .milliseconds(250))
            }
            previewArtifact = WorkspaceArtifact(path: artifactPath)
        }
        #endif
    }

    /// CI tour fixtures for the Files surfaces that have never been
    /// photographed: the code editor, the comparison sheet, and search.
    /// Copies the --workbench-open-artifact-preview pattern.
    func openFilesSurfaceDemosIfRequested() {
        #if DEBUG || targetEnvironment(simulator)
        let arguments = ProcessInfo.processInfo.arguments
        guard !didOpenFilesSurfaceDemo else { return }

        if arguments.contains("--open-code-editor-demo") {
            didOpenFilesSurfaceDemo = true
            Task { @MainActor in
                for _ in 0..<14 {
                    if let row = items.first(where: { !$0.item.isDirectory }) {
                        editingTarget = FileEditTarget(item: row.item)
                        return
                    }
                    try? await Task.sleep(for: .milliseconds(300))
                }
            }
            return
        }

        if arguments.contains("--open-file-comparison-demo") {
            didOpenFilesSurfaceDemo = true
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(600))
                comparisonDraft = FileComparisonDraft(
                    title: "README.md → docs/README.md",
                    sourcePath: "README.md",
                    destinationPath: "docs/README.md",
                    summary: "Moved during workspace reorganization · 6 lines changed",
                    diffText: """
                    - # NovaForge workspace
                    + # NovaForge
                    +
                    + On-device agent workspace. Evidence, proof receipts,
                    + and generated artifacts land in this tree.
                      Files created by runs appear under their run id.
                    """
                )
            }
            return
        }

        if arguments.contains("--open-files-search-demo") {
            didOpenFilesSurfaceDemo = true
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(700))
                searchQuery = "proof"
                showingSearch = true
                try? await Task.sleep(for: .milliseconds(500))
                runSearch()
            }
            return
        }
        #endif
    }

    func canPreview(_ item: FileItem) -> Bool {
        guard !item.isDirectory else { return false }
        return canPreviewPath(item.relativePath)
    }

    func canPreviewPath(_ path: String) -> Bool {
        WorkspaceArtifact(path: path).isReadablePreviewArtifact
    }

    func readableEvidencePath(_ path: String) -> String {
        let name = URL(fileURLWithPath: path).lastPathComponent
        return name.isEmpty ? path : name
    }

    func parentPath(for path: String) -> String {
        path
            .split(separator: "/", omittingEmptySubsequences: false)
            .dropLast()
            .joined(separator: "/")
    }

    func goUp() {
        guard !currentPath.isEmpty else { return }
        currentPath = currentPath.components(separatedBy: "/").dropLast().joined(separator: "/")
        reload()
    }

}

struct FileMetricPill: View {
    let value: String
    let label: String
    let symbol: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: symbol)
                    .font(.system(size: 7, weight: .heavy))
                Text(label)
                    .font(.system(size: 7, weight: .black, design: AgentPalette.interfaceFontDesign))
                    .textCase(.uppercase)
            }
            .foregroundStyle(AgentPalette.tertiaryText)
            Text(value)
                .font(.system(size: 12, weight: .black, design: AgentPalette.interfaceFontDesign))
                .foregroundStyle(AgentPalette.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.66)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .agentRowSurface(radius: 12, tint: tint.opacity(0.07))
    }
}

private struct FilesEmptyState: View {
    let create: () -> Void
    let openChat: () -> Void

    var body: some View {
        NovaGlassEmptyState(
            symbol: "folder.badge.plus",
            title: "Nothing forged here yet",
            detail: "This workspace folder is standing by. Create the first file, or hand NovaForge a mission from Chat and it will land evidence here.",
            tint: AgentPalette.cyan,
            actions: [
                .init(
                    title: "New File",
                    symbol: "doc.badge.plus",
                    tint: AgentPalette.cyan,
                    accessibilityIdentifier: "filesEmptyCreateFile",
                    handler: create
                ),
                .init(
                    title: "Ask Chat",
                    symbol: "sparkles",
                    tint: AgentPalette.lilac,
                    accessibilityIdentifier: "filesEmptyOpenChat",
                    handler: openChat
                )
            ]
        )
        .padding(.vertical, 12)
    }
}

private struct FilesLoadErrorState: View {
    let path: String
    let message: String
    let retry: () -> Void
    let goHome: () -> Void

    private var title: String {
        path.isEmpty ? "Workspace unavailable" : "Folder unavailable"
    }

    private var detail: String {
        path.isEmpty ? message : "\(path): \(message)"
    }

    var body: some View {
        VStack(spacing: 12) {
            AgentCenteredStateView(
                title: title,
                detail: detail,
                symbol: "folder.badge.questionmark",
                tint: AgentPalette.rose
            )
            .padding(.vertical, 4)

            HStack(spacing: 10) {
                Button {
                    retry()
                } label: {
                    Label("Retry", systemImage: "arrow.clockwise")
                        .frame(maxWidth: .infinity, minHeight: AgentDesign.minimumTouchTarget)
                }
                .buttonStyle(.borderedProminent)
                .tint(AgentPalette.rose)
                .accessibilityIdentifier("filesLoadRetry")

                if !path.isEmpty {
                    Button {
                        goHome()
                    } label: {
                        Label("Home", systemImage: "house")
                            .frame(maxWidth: .infinity, minHeight: AgentDesign.minimumTouchTarget)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("filesLoadGoHome")
                }
            }
            .padding(.horizontal)
        }
        .padding(.vertical, 12)
    }
}

struct FileSearchPrompt: View {
    var body: some View {
        AgentCenteredStateView(
            title: "Search files, symbols, and notes",
            detail: "Results stay capped so large workspaces remain smooth.",
            symbol: "doc.text.magnifyingglass",
            tint: AgentPalette.cyan
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct FileSearchResultRow: View {
    let result: SearchResultItem
    let query: String
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(result.fileName)
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(AgentPalette.ink)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Spacer(minLength: 8)

                    Text("Line \(result.lineNumber)")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(AgentPalette.cyan)
                }

                Text(result.relativePath)
                    .font(.system(size: 10, weight: .semibold, design: AgentPalette.interfaceFontDesign))
                    .foregroundStyle(AgentPalette.tertiaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Text(highlightedText(content: result.lineContent, query: query))
                    .font(.system(size: 11, design: .monospaced))
                    .lineLimit(2)
            }
            .padding(12)
            .agentRowSurface(radius: 14, tint: AgentPalette.cyan)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(result.fileName), line \(result.lineNumber), \(result.relativePath)")
    }

    private func highlightedText(content: String, query: String) -> AttributedString {
        var attributedString = AttributedString(content)
        guard !query.isEmpty else { return attributedString }

        let lowerContent = content.lowercased()
        let lowerQuery = query.lowercased()
        var searchRange = lowerContent.startIndex..<lowerContent.endIndex
        while let range = lowerContent.range(of: lowerQuery, options: [], range: searchRange) {
            let startDistance = lowerContent.distance(from: lowerContent.startIndex, to: range.lowerBound)
            let endDistance = lowerContent.distance(from: lowerContent.startIndex, to: range.upperBound)
            let start = attributedString.index(attributedString.startIndex, offsetByCharacters: startDistance)
            let end = attributedString.index(attributedString.startIndex, offsetByCharacters: endDistance)
            attributedString[start..<end].foregroundColor = .black
            attributedString[start..<end].backgroundColor = AgentPalette.cyan
            attributedString[start..<end].font = .system(size: 11, weight: .bold, design: .monospaced)
            searchRange = range.upperBound..<lowerContent.endIndex
        }
        return attributedString
    }
}

struct CreateFileSheet: View {
    let currentPath: String
    let createMutation: @MainActor (String, Bool) async throws -> Void
    let onCreated: (String, Bool) -> Void
    
    @Environment(\.dismiss) private var dismiss
    @State private var fileName = ""
    @State private var isDirectory = false
    @State private var errorMessage: String? = nil
    @State private var creationTask: Task<Void, Never>?
    @State private var isCreating = false
    @FocusState private var nameFocused: Bool

    private var trimmedName: String {
        fileName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var createDisabled: Bool {
        trimmedName.isEmpty || isCreating
    }
    
    var body: some View {
        ZStack {
            AgentBackground()
            VStack(alignment: .leading, spacing: 16) {
                HeaderView(
                    title: isDirectory ? "New Folder" : "New File",
                    subtitle: currentPath.isEmpty ? "Root Directory" : "In: \(currentPath)",
                    symbol: isDirectory ? "folder.badge.plus" : "doc.badge.plus"
                )
                
                HStack(spacing: 12) {
                    Button {
                        let impact = UIImpactFeedbackGenerator(style: .light)
                        impact.impactOccurred()
                        withAnimation { isDirectory = false }
                    } label: {
                        Label("File", systemImage: "doc")
                            .font(.subheadline.weight(.bold))
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .agentControlSurface(radius: 12, tint: AgentPalette.cyan, selected: !isDirectory)
                    }
                    .buttonStyle(.plain)
                    .disabled(isCreating)
                    
                    Button {
                        let impact = UIImpactFeedbackGenerator(style: .light)
                        impact.impactOccurred()
                        withAnimation { isDirectory = true }
                    } label: {
                        Label("Folder", systemImage: "folder")
                            .font(.subheadline.weight(.bold))
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .agentControlSurface(radius: 12, tint: AgentPalette.cyan, selected: isDirectory)
                    }
                    .buttonStyle(.plain)
                    .disabled(isCreating)
                }
                
                TextField(isDirectory ? "Folder name..." : "File name...", text: $fileName)
                    .textFieldStyle(.plain)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.none)
                    .submitLabel(.done)
                    .focused($nameFocused)
                    .padding(12)
                    .disabled(isCreating)
                    .agentControlSurface(radius: 14, tint: isDirectory ? AgentPalette.cyan : AgentPalette.cyan)
                    .onSubmit {
                        guard !createDisabled else { return }
                        create()
                    }
                    .onChange(of: fileName) {
                        errorMessage = nil
                    }
                    .accessibilityIdentifier("createFileNameField")
                
                if let errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(AgentPalette.rose)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("createFileError")
                }
                
                HStack(spacing: 12) {
                    Button("Cancel") {
                        dismiss()
                    }
                    .buttonStyle(.bordered)
                    .disabled(isCreating)
                    .frame(maxWidth: .infinity)
                    .accessibilityIdentifier("createFileCancelButton")
                    
                    Button(isCreating ? "Creating…" : "Create") { create() }
                    .buttonStyle(.borderedProminent)
                    .tint(isDirectory ? AgentPalette.cyan : AgentPalette.cyan)
                    .disabled(createDisabled)
                    .frame(maxWidth: .infinity)
                    .accessibilityIdentifier("createFileSubmitButton")
                }
            }
            .padding()
        }
        .onAppear {
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(180))
                nameFocused = true
            }
        }
        .interactiveDismissDisabled(isCreating)
        .onDisappear {
            creationTask?.cancel()
            creationTask = nil
        }
    }
    
    private func create() {
        let name = trimmedName
        guard !name.isEmpty, creationTask == nil else { return }
        
        let targetRelativePath = currentPath.isEmpty ? name : "\(currentPath)/\(name)"
        let creatingDirectory = isDirectory
        isCreating = true
        errorMessage = nil
        creationTask = Task { @MainActor in
            defer {
                isCreating = false
                creationTask = nil
            }
            do {
                try await createMutation(targetRelativePath, creatingDirectory)
                let successImpact = UINotificationFeedbackGenerator()
                successImpact.notificationOccurred(.success)
                onCreated(targetRelativePath, creatingDirectory)
                dismiss()
            } catch {
                guard !Self.isQuietCancellation(error) else {
                    return
                }
                let errorImpact = UINotificationFeedbackGenerator()
                errorImpact.notificationOccurred(.error)
                let action = creatingDirectory
                    ? "Could not create folder"
                    : "Could not create file"
                errorMessage = "\(action): \(error.localizedDescription)"
            }
        }
    }

    private static func isQuietCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        return (error as? AgentPolicyMutationServiceError) == .cancelled
    }
}

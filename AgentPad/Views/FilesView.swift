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

private struct FileSearchStats: Equatable, Sendable {
    var scannedFiles = 0
    var skippedLargeFiles = 0
    var skippedUnsafePaths = 0
    var searchedDirectories = 0
    var capped = false
}

private struct FileEditTarget: Identifiable, Hashable, Sendable {
    let item: FileItem
    var focusedLineNumber: Int?

    var id: String {
        "\(item.id):\(focusedLineNumber.map(String.init) ?? "start")"
    }
}

struct FilesView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var settingsList: [AgentSettings]
    
    var runtime: AgentRuntime
    var project: Project
    let openArtifactLandscapeFullScreen: (WorkspaceArtifact) -> Void
    let openChat: () -> Void
    @SceneStorage("novaforge.files.currentPath") private var currentPath = ""
    @SceneStorage("novaforge.files.selectedMemoryItemID") private var selectedMemoryItemID = ""
    @AppStorage("novaforge.files.workbenchLens") private var workbenchLensRawValue = FileWorkbenchLens.all.rawValue
    @AppStorage("novaforge.files.inspectorMode") private var inspectorModeRawValue = FileInspectorMode.details.rawValue
    @AppStorage("novaforge.files.gridLayout") private var isGridLayout = false
    @State private var items: [FileRowData] = []
    @State private var editingTarget: FileEditTarget? = nil
    @State private var pendingSearchOpenTarget: FileEditTarget? = nil
    @State private var previewArtifact: WorkspaceArtifact? = nil
    @State private var comparisonDraft: FileComparisonDraft? = nil
    @State private var relatedContextDraft: FileRelatedContextDraft? = nil
    @State private var importantMemoryPaths: Set<String> = []
    @State private var pinnedMemoryPaths: Set<String> = []
    @State private var transientNotice: String?
    @State private var showingCreate = false
    @State private var newFileName = ""
    
    @State private var workspaces: [String] = []
    @State private var showingCreateWorkspace = false
    @State private var newWorkspaceName = ""
    
    // Search panel options
    @State private var searchQuery = ""
    @State private var showingSearch = false
    @State private var searchResults: [SearchResultItem] = []
    @State private var searchStats = FileSearchStats()
    @State private var isSearching = false
    @State private var hasSearchedFiles = false
    @State private var lastSearchQuery = ""
    @State private var searchErrorMessage: String?
    @State private var activeSearchID: UUID?
    @State private var searchTask: Task<Void, Never>?
    @State private var reloadTask: Task<Void, Never>?
    @State private var fileActionTask: Task<Void, Never>?
    @State private var fileActionStatus: String?
    @State private var fileActionError: String?
    @State private var fileLoadError: String?
    @State private var workspaceSaveError: String?
    @State private var pendingDeleteItem: FileItem?
    @State private var didSeedFileStress = false
    @State private var didOpenDebugArtifactPreview = false
    @FocusState private var searchFocused: Bool
    
    private var settings: AgentSettings? { settingsList.first }
    @State private var isExporting = false
    @State private var recentCutoff = Date().addingTimeInterval(-300)
    @State private var cachedStats = FileStats()

    private let tabBarClearance: CGFloat = BottomDockMetrics.scrollClearance
    private let searchResultLimit = 200

    private var missionContract: MissionOSContract {
        ProjectMissionSummarizer.summarize(project: project, context: modelContext).missionContract
    }

    private var artifactIterationPrompt: String {
        ProjectMissionSummarizer.summarize(project: project, context: modelContext).workflowSpine.iterationPrompt
    }

    private struct FileStats {
        var folderCount = 0
        var fileCount = 0
        var totalBytes: Int64 = 0
        var totalBytesText = "0 B"
        var previewableCount = 0
        var recentCount = 0
        var newestName: String?
        var newestDate: Date?
    }

    private enum FileVisualKind: Hashable, Sendable {
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

    private struct FileRowData: Identifiable, Hashable, Sendable {
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

    private enum FileWorkbenchLens: String, CaseIterable, Identifiable {
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

    private enum FileInspectorMode: String, CaseIterable, Identifiable {
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

    private enum ProjectMemoryGroup: String, CaseIterable, Identifiable {
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

    private enum ProjectMemoryRisk: String {
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

    private struct ProjectMemoryItem: Identifiable {
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

    private struct ProjectMemorySection: Identifiable {
        let group: ProjectMemoryGroup
        let items: [ProjectMemoryItem]

        var id: String { group.rawValue }
    }

    private struct FileComparisonDraft: Identifiable {
        let id = UUID()
        let title: String
        let sourcePath: String
        let destinationPath: String
        let summary: String
        let diffText: String
    }

    private struct FileRelatedContextDraft: Identifiable {
        let id = UUID()
        let title: String
        let subtitle: String
        let detail: String
        let symbol: String
        let tint: Color
    }

    private struct FileComparisonSheet: View {
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

    private struct FileRelatedContextSheet: View {
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

    private var selectedWorkbenchLens: FileWorkbenchLens {
        FileWorkbenchLens(rawValue: workbenchLensRawValue) ?? .all
    }

    private var selectedInspectorMode: FileInspectorMode {
        FileInspectorMode(rawValue: inspectorModeRawValue) ?? .details
    }

    private var projectMemoryItems: [ProjectMemoryItem] {
        let artifactItems = project.artifacts.map(memoryItem(for:))
        let changeItems = project.fileChanges.map(memoryItem(for:))
        let fileItems = items.map(memoryItem(for:))
        return (artifactItems + changeItems + fileItems)
            .sorted(by: compareMemoryItems)
    }

    private var filteredProjectMemoryItems: [ProjectMemoryItem] {
        projectMemoryItems.filter { $0.matches(selectedWorkbenchLens) }
    }

    private var selectedMemoryItem: ProjectMemoryItem? {
        if !selectedMemoryItemID.isEmpty,
           let selected = projectMemoryItems.first(where: { $0.id == selectedMemoryItemID }) {
            return selected
        }
        return filteredProjectMemoryItems.first
    }

    private var projectMemorySections: [ProjectMemorySection] {
        let grouped = Dictionary(grouping: filteredProjectMemoryItems, by: \.group)
        return grouped
            .map { ProjectMemorySection(group: $0.key, items: $0.value.sorted(by: compareMemoryItems)) }
            .sorted {
                if $0.group.priority != $1.group.priority { return $0.group.priority < $1.group.priority }
                return $0.group.title < $1.group.title
            }
    }

    private var artifactGalleryItems: [ProjectMemoryItem] {
        filteredProjectMemoryItems
            .filter { item in
                item.group == .artifacts || item.group == .screenshots || item.isGenerated || item.isVerification
            }
            .prefix(8)
            .map { $0 }
    }

    private var memoryIsStale: Bool {
        guard let newest = projectMemoryItems.compactMap(\.timestamp).max() else { return false }
        return newest < Date().addingTimeInterval(-86_400)
    }

    private var memoryPreferencePrefix: String {
        "novaforge.files.memory.\(project.id.uuidString)"
    }

    private var changedFileCount: Int {
        projectMemoryItems.filter { $0.group == .changed }.count
    }

    private var artifactCount: Int {
        projectMemoryItems.filter { $0.group == .artifacts || $0.isGenerated }.count
    }

    private var verificationCount: Int {
        projectMemoryItems.filter { $0.isVerification || $0.isScreenshot }.count
    }

    private var riskCount: Int {
        projectMemoryItems.filter { $0.risk == .elevated || $0.risk == .high }.count
    }

    private func memoryItem(for row: FileRowData) -> ProjectMemoryItem {
        let item = row.item
        let path = item.relativePath
        let artifact = WorkspaceArtifact(path: path)
        let relatedChange = project.fileChanges.first { change in
            change.path == path || change.path.components(separatedBy: " -> ").contains(path)
        }
        let isScreenshot = isScreenshotPath(path)
        let isVerification = isVerificationPath(path) || artifact.isReportArtifact || artifact.isLogArtifact
        let isGenerated = isGeneratedPath(path)
        let group = memoryGroup(
            path: path,
            isDirectory: item.isDirectory,
            isArtifact: project.artifacts.contains { $0.path == path },
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
            origin: currentPath.isEmpty ? "Workspace root" : "Workspace folder",
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
            sourceEventIDString: relatedChange?.sourceEventIDString
        )
    }

    private func memoryItem(for artifactRecord: ProjectArtifact) -> ProjectMemoryItem {
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
            origin: artifactRecord.sourceToolRunIDString == nil ? "Project artifact" : "Tool run artifact",
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
            sourceEventIDString: nil
        )
    }

    private func memoryItem(for change: ProjectFileChange) -> ProjectMemoryItem {
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
            origin: change.sourceToolRunIDString == nil ? "Workspace change" : "Tool run change",
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
            sourceEventIDString: change.sourceEventIDString
        )
    }

    private func compareMemoryItems(_ lhs: ProjectMemoryItem, _ rhs: ProjectMemoryItem) -> Bool {
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

    private func memoryGroup(
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

    private func riskFor(path: String, action: String?, isFailed: Bool, group: ProjectMemoryGroup) -> ProjectMemoryRisk {
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

    private func isScreenshotPath(_ path: String) -> Bool {
        let lower = path.lowercased()
        return lower.contains("screenshot") || lower.contains("screen-shot") || lower.contains("snapshots/") || ["png", "jpg", "jpeg", "webp"].contains(URL(fileURLWithPath: path).pathExtension.lowercased())
    }

    private func isVerificationPath(_ path: String) -> Bool {
        let lower = path.lowercased()
        return lower.contains("proof") || lower.contains("verify") || lower.contains("verification") || lower.contains("qa/") || lower.contains("test") || lower.contains("report") || lower.contains("log")
    }

    private func isGeneratedPath(_ path: String) -> Bool {
        let lower = path.lowercased()
        return lower.contains("generated") || lower.contains("artifact") || lower.contains("output") || lower.contains("export")
    }

    private func isFailurePath(_ path: String) -> Bool {
        let lower = path.lowercased()
        return lower.contains("failed") || lower.contains("failure") || lower.contains("error")
    }

    private func fileDetail(for artifact: WorkspaceArtifact, item: FileItem) -> String {
        if item.isDirectory { return "Workspace folder with current project material." }
        if artifact.isImageArtifact { return artifact.path.lowercased().contains("screenshot") ? "Visual verification evidence." : "Image output in the workspace." }
        if artifact.isMarkdownArtifact || artifact.isReportArtifact { return "Readable report or notes output." }
        if artifact.isLogArtifact { return "Log evidence captured in the workspace." }
        if artifact.isWebPage { return "Previewable HTML artifact." }
        if artifact.artifactType == .source { return "Source file available for review." }
        return "Workspace file available for inspection."
    }

    private func reviewSummary(for action: String, path: String) -> String {
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

    private func changeStatus(for action: String) -> String {
        if action.localizedCaseInsensitiveContains("deleted") { return "Deleted" }
        if action.localizedCaseInsensitiveContains("created") { return "Created" }
        if action.localizedCaseInsensitiveContains("duplicated") { return "Duplicated" }
        if action.localizedCaseInsensitiveContains("saved") { return "Saved" }
        return "Changed"
    }

    private func comparisonDestination(in path: String) -> (source: String, destination: String)? {
        let parts = path.components(separatedBy: " -> ")
        guard parts.count == 2 else { return nil }
        let source = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
        let destination = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty, !destination.isEmpty else { return nil }
        return (source: source, destination: destination)
    }

    private func fileSizeText(for path: String) -> String? {
        guard let url = try? runtime.workspace.resolve(path),
              let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize else {
            return nil
        }
        return Self.byteCountString(Int64(size))
    }

    private func dateText(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    var body: some View {
        ZStack {
            VStack(spacing: 12) {
                HeaderView(
                    title: "Files",
                    subtitle: "\(project.name) · \(runtime.workspace.workspaceName)",
                    symbol: "folder.fill",
                    tint: AgentPalette.cyan
                )
                .padding(.horizontal)
                .padding(.top, 14)

                if runtime.shouldShowWorkspaceStatusStrip {
                    WorkspaceStatusStrip(runtime: runtime, openChat: openChat)
                        .padding(.horizontal)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }

                MissionOSStatusStrip(contract: missionContract, surfaceName: "Files")
                    .equatable()
                    .padding(.horizontal)
                    .transition(.move(edge: .top).combined(with: .opacity))

                projectExplorerOverview
                    .padding(.horizontal)

                if hasProjectEvidenceShortcuts {
                    projectEvidenceShortcuts
                        .padding(.horizontal)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }

                if !items.isEmpty {
                    fileStats
                        .padding(.horizontal)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }

                breadcrumbs
                actionBar
                    .padding(.horizontal)

                ScrollView(showsIndicators: false) {
                    LazyVStack(spacing: 14) {
                        projectMemoryWorkbench
                            .padding(.horizontal)
                            .padding(.top, 2)

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
                            if isGridLayout {
                                gridLayout
                            } else {
                                listLayout
                            }
                        }
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
        .task {
            loadMemoryFlags()
            seedFileStressIfNeeded()
            reload()
            reloadWorkspaces()
            openDebugArtifactPreviewIfRequested()
        }
        .onChange(of: project.id) { _, _ in
            selectedMemoryItemID = ""
            loadMemoryFlags()
        }
        .sheet(item: $editingTarget) { target in
            CodeEditorView(
                fileName: target.item.name,
                relativePath: target.item.relativePath,
                workspace: runtime.workspace,
                initialLineNumber: target.focusedLineNumber,
                onSave: {
                    runtime.noteWorkspaceChanged()
                    ProjectEventRecorder.recordFileChange(
                        project: project,
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
        .sheet(item: $relatedContextDraft) { draft in
            FileRelatedContextSheet(draft: draft)
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
        }
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
        .sheet(isPresented: $showingCreate) {
            CreateFileSheet(workspace: runtime.workspace, currentPath: currentPath) { path, isDirectory in
                runtime.noteWorkspaceChanged()
                ProjectEventRecorder.recordFileChange(
                    project: project,
                    action: isDirectory ? "Created folder" : "Created file",
                    path: path,
                    context: modelContext
                )
                saveFileEvidence(
                    failureMessage: "Created \(isDirectory ? "folder" : "file") \(path), but NovaForge could not save the project proof record"
                )
                reload()
            }
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
        .scrollDismissesKeyboard(.interactively)
    }

    private var projectExplorerOverview: some View {
        HStack(spacing: 10) {
            Image(systemName: "rectangle.stack.badge.play")
                .font(.system(size: 13, weight: .black))
                .foregroundStyle(AgentPalette.cyan)
                .frame(width: 32, height: 32)
                .background(AgentPalette.cyan.opacity(0.12), in: RoundedRectangle(cornerRadius: 11, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 7) {
                    Text(currentPath.isEmpty ? "Root workspace" : currentPath)
                        .font(.system(size: 12, weight: .black, design: AgentPalette.interfaceFontDesign))
                        .foregroundStyle(AgentPalette.ink)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text("\(cachedStats.fileCount) file\(cachedStats.fileCount == 1 ? "" : "s")")
                        .font(.system(size: 9, weight: .black, design: AgentPalette.interfaceFontDesign))
                        .foregroundStyle(AgentPalette.lilac)
                        .lineLimit(1)
                }

                Text(compactProjectSummary)
                    .font(.system(size: 9.5, weight: .bold, design: AgentPalette.interfaceFontDesign))
                    .foregroundStyle(AgentPalette.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer(minLength: 0)

            Text(cachedStats.totalBytesText)
                .font(.system(size: 9, weight: .black, design: AgentPalette.interfaceFontDesign))
                .foregroundStyle(AgentPalette.storageAccent)
                .padding(.horizontal, 8)
                .frame(height: 24)
                .agentControlSurface(radius: 9, tint: AgentPalette.storageAccent.opacity(0.10), selected: false)
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 52)
        .agentSurface(radius: 18, tint: AgentPalette.cyan.opacity(0.06))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Project Explorer")
        .accessibilityIdentifier("filesProjectOverview")
    }

    private var projectExplorerSubtitle: String {
        if items.isEmpty { return "Empty workspace ready for files" }
        return "\(items.count) item\(items.count == 1 ? "" : "s") in this folder · previews open instantly"
    }

    private var compactProjectSummary: String {
        var parts: [String] = []
        if cachedStats.folderCount > 0 {
            parts.append("\(cachedStats.folderCount) folder\(cachedStats.folderCount == 1 ? "" : "s")")
        }
        if cachedStats.previewableCount > 0 {
            parts.append("\(cachedStats.previewableCount) preview\(cachedStats.previewableCount == 1 ? "" : "s")")
        }
        parts.append(cachedStats.recentCount > 0
            ? "\(cachedStats.recentCount) fresh change\(cachedStats.recentCount == 1 ? "" : "s")"
            : "no fresh changes")
        if let newest = cachedStats.newestName { parts.append("latest: \(newest)") }
        return parts.joined(separator: " · ")
    }

    private var latestProjectArtifact: ProjectArtifact? {
        project.artifacts.sorted { lhs, rhs in
            if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
            return lhs.path < rhs.path
        }.first
    }

    private var latestProjectFileChange: ProjectFileChange? {
        project.fileChanges.sorted { lhs, rhs in
            if lhs.createdAt != rhs.createdAt { return lhs.createdAt > rhs.createdAt }
            return lhs.path < rhs.path
        }.first
    }

    private var hasProjectEvidenceShortcuts: Bool {
        latestProjectArtifact != nil || latestProjectFileChange != nil
    }

    private var projectEvidenceShortcuts: some View {
        HStack(spacing: 8) {
            if let artifact = latestProjectArtifact {
                projectEvidenceButton(
                    title: "Latest artifact",
                    detail: artifact.title.isEmpty ? artifact.path : artifact.title,
                    symbol: artifact.kind == .web || artifact.previewMode == .web ? "play.rectangle.fill" : "shippingbox.fill",
                    tint: artifact.previewMode == .web || artifact.previewMode == .nativeGame ? AgentPalette.green : AgentPalette.cyan
                ) {
                    previewArtifactPath(artifact.path)
                }
            }

            if let change = latestProjectFileChange {
                projectEvidenceButton(
                    title: "Latest change",
                    detail: readableEvidencePath(change.path),
                    symbol: "doc.text.fill",
                    tint: AgentPalette.lilac
                ) {
                    openWorkspaceEvidencePath(change.path)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("filesProjectEvidenceShortcuts")
    }

    private func projectEvidenceButton(
        title: String,
        detail: String,
        symbol: String,
        tint: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            action()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 10.5, weight: .black))
                    .foregroundStyle(tint)
                    .frame(width: 26, height: 26)
                    .background(tint.opacity(0.11), in: RoundedRectangle(cornerRadius: 9, style: .continuous))

                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 8, weight: .black, design: AgentPalette.interfaceFontDesign))
                        .foregroundStyle(AgentPalette.tertiaryText)
                        .textCase(.uppercase)
                    Text(detail)
                        .font(.system(size: 10, weight: .semibold, design: AgentPalette.interfaceFontDesign))
                        .foregroundStyle(AgentPalette.secondaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(9)
            .frame(maxWidth: .infinity, minHeight: 50, alignment: .leading)
            .agentRowSurface(radius: 15, tint: tint.opacity(0.12), selected: true)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title): \(detail)")
    }

    private var projectMemoryWorkbench: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "rectangle.stack.badge.person.crop.fill")
                    .font(.system(size: 14, weight: .black))
                    .foregroundStyle(AgentPalette.green)
                    .frame(width: 34, height: 34)
                    .agentControlSurface(radius: 12, tint: AgentPalette.green.opacity(0.12), selected: true)

                VStack(alignment: .leading, spacing: 3) {
                    Text("Project Memory")
                        .font(.system(size: 14, weight: .black, design: AgentPalette.interfaceFontDesign))
                        .foregroundStyle(AgentPalette.ink)
                    Text(projectMemorySubtitle)
                        .font(.system(size: 10, weight: .semibold, design: AgentPalette.interfaceFontDesign))
                        .foregroundStyle(AgentPalette.secondaryText)
                        .lineLimit(2)
                }

                Spacer(minLength: 0)

                if memoryIsStale {
                    Label("Stale", systemImage: "clock.badge.exclamationmark")
                        .font(.system(size: 9, weight: .black, design: AgentPalette.interfaceFontDesign))
                        .foregroundStyle(AgentPalette.warning)
                        .padding(.horizontal, 8)
                        .frame(height: 24)
                        .agentControlSurface(radius: 8, tint: AgentPalette.warning.opacity(0.12), selected: true)
                }
            }

            memoryMetricsRow
            workbenchLensBar

            if projectMemoryItems.isEmpty {
                AgentInlineStateView(
                    title: "No project memory yet",
                    detail: "Artifacts, screenshots, verification proof, and changed files will appear here as work lands.",
                    symbol: "tray",
                    tint: AgentPalette.secondaryText
                )
            } else if filteredProjectMemoryItems.isEmpty {
                AgentInlineStateView(
                    title: "No \(selectedWorkbenchLens.title.lowercased()) evidence",
                    detail: "Switch filters or create new proof from Chat.",
                    symbol: selectedWorkbenchLens.symbol,
                    tint: selectedWorkbenchLens.tint
                )
            } else {
                if let selectedMemoryItem {
                    memoryInspector(for: selectedMemoryItem)
                }

                if !artifactGalleryItems.isEmpty {
                    artifactGallery
                }

                memorySectionsList
            }
        }
        .padding(14)
        .agentSurface(radius: 22, tint: AgentPalette.green.opacity(0.06))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("filesProjectMemoryWorkbench")
    }

    private var projectMemorySubtitle: String {
        if projectMemoryItems.isEmpty {
            return "Waiting for generated outputs and file evidence"
        }
        var parts: [String] = []
        if changedFileCount > 0 { parts.append("\(changedFileCount) change\(changedFileCount == 1 ? "" : "s")") }
        if artifactCount > 0 { parts.append("\(artifactCount) artifact\(artifactCount == 1 ? "" : "s")") }
        if verificationCount > 0 { parts.append("\(verificationCount) proof item\(verificationCount == 1 ? "" : "s")") }
        if riskCount > 0 { parts.append("\(riskCount) needs review") }
        return parts.isEmpty ? "\(projectMemoryItems.count) workspace item\(projectMemoryItems.count == 1 ? "" : "s")" : parts.joined(separator: " · ")
    }

    private var memoryMetricsRow: some View {
        HStack(spacing: 8) {
            FileMetricPill(value: "\(changedFileCount)", label: "Changes", symbol: "doc.badge.gearshape.fill", tint: AgentPalette.cyan)
            FileMetricPill(value: "\(artifactCount)", label: "Artifacts", symbol: "shippingbox.fill", tint: AgentPalette.green)
            FileMetricPill(value: "\(verificationCount)", label: "Proof", symbol: "checkmark.seal.fill", tint: AgentPalette.lilac)
            FileMetricPill(value: "\(riskCount)", label: "Risk", symbol: "exclamationmark.triangle.fill", tint: riskCount > 0 ? AgentPalette.warning : AgentPalette.secondaryText)
        }
    }

    private var workbenchLensBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 7) {
                ForEach(FileWorkbenchLens.allCases) { lens in
                    Button {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        workbenchLensRawValue = lens.rawValue
                    } label: {
                        Label(lens.title, systemImage: lens.symbol)
                            .font(.system(size: 10, weight: .black, design: AgentPalette.interfaceFontDesign))
                            .lineLimit(1)
                            .foregroundStyle(selectedWorkbenchLens == lens ? AgentPalette.ink : AgentPalette.secondaryText)
                            .padding(.horizontal, 9)
                            .frame(height: 34)
                            .agentControlSurface(
                                radius: 11,
                                tint: lens.tint.opacity(selectedWorkbenchLens == lens ? 0.15 : 0.06),
                                selected: selectedWorkbenchLens == lens
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("filesMemoryLens-\(lens.rawValue)")
                }
            }
            .padding(.vertical, 1)
        }
    }

    private func memoryInspector(for item: ProjectMemoryItem) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: item.symbol)
                    .font(.system(size: 14, weight: .black))
                    .foregroundStyle(item.tint)
                    .frame(width: 34, height: 34)
                    .agentControlSurface(radius: 12, tint: item.tint.opacity(0.12), selected: true)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(item.title)
                            .font(.system(size: 13, weight: .black, design: AgentPalette.interfaceFontDesign))
                            .foregroundStyle(AgentPalette.ink)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if item.isPinned {
                            Image(systemName: "pin.fill")
                                .font(.system(size: 9, weight: .black))
                                .foregroundStyle(AgentPalette.warning)
                        }
                        if item.isImportant {
                            Image(systemName: "star.fill")
                                .font(.system(size: 9, weight: .black))
                                .foregroundStyle(AgentPalette.warning)
                        }
                    }

                    Text(item.primaryPath)
                        .font(.system(size: 10, weight: .semibold, design: AgentPalette.interfaceFontDesign))
                        .foregroundStyle(AgentPalette.secondaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer(minLength: 0)

                Label(item.risk.title, systemImage: item.risk.symbol)
                    .font(.system(size: 9, weight: .black, design: AgentPalette.interfaceFontDesign))
                    .foregroundStyle(item.risk.tint)
                    .padding(.horizontal, 8)
                    .frame(height: 24)
                    .agentControlSurface(radius: 8, tint: item.risk.tint.opacity(0.12), selected: true)
            }

            inspectorModePicker

            if selectedInspectorMode == .details {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                    memoryMetadataCell(title: "Type", value: item.group.title, symbol: item.group.symbol, tint: item.group.tint)
                    memoryMetadataCell(title: "Status", value: item.status, symbol: "waveform.path.ecg", tint: item.tint)
                    memoryMetadataCell(title: "Updated", value: item.timestampText, symbol: "clock.fill", tint: AgentPalette.lilac)
                    memoryMetadataCell(title: "Origin", value: item.origin, symbol: "point.3.connected.trianglepath.dotted", tint: AgentPalette.cyan)
                    memoryMetadataCell(title: "Size", value: item.sizeText ?? "Unknown", symbol: "internaldrive.fill", tint: AgentPalette.storageAccent)
                    memoryMetadataCell(title: "Path", value: item.primaryPath, symbol: "folder.fill", tint: AgentPalette.secondaryText)
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    AgentInlineStateView(
                        title: item.status,
                        detail: item.detail,
                        symbol: item.risk.symbol,
                        tint: item.risk.tint
                    )
                    HStack(spacing: 8) {
                        memoryTag("Risk \(item.risk.title)", symbol: item.risk.symbol, tint: item.risk.tint)
                        if item.hasRelatedContext {
                            memoryTag("Linked Run", symbol: "point.3.connected.trianglepath.dotted", tint: AgentPalette.cyan)
                        }
                        if item.comparisonPaths != nil {
                            memoryTag("Comparable", symbol: "arrow.left.arrow.right", tint: AgentPalette.lilac)
                        }
                    }
                }
            }

            memoryQuickActions(for: item)
        }
        .padding(12)
        .agentSurface(radius: 18, tint: item.tint.opacity(0.06))
        .accessibilityIdentifier("filesMemoryInspector")
    }

    private var inspectorModePicker: some View {
        HStack(spacing: 7) {
            ForEach(FileInspectorMode.allCases) { mode in
                Button {
                    inspectorModeRawValue = mode.rawValue
                } label: {
                    Label(mode.title, systemImage: mode.symbol)
                        .font(.system(size: 10, weight: .black, design: AgentPalette.interfaceFontDesign))
                        .frame(maxWidth: .infinity)
                        .frame(height: 34)
                        .foregroundStyle(selectedInspectorMode == mode ? AgentPalette.ink : AgentPalette.secondaryText)
                        .agentControlSurface(
                            radius: 11,
                            tint: AgentPalette.cyan.opacity(selectedInspectorMode == mode ? 0.14 : 0.05),
                            selected: selectedInspectorMode == mode
                        )
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("filesInspectorMode-\(mode.rawValue)")
            }
        }
    }

    private func memoryMetadataCell(title: String, value: String, symbol: String, tint: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .black))
                .foregroundStyle(tint)
                .frame(width: 24, height: 24)
                .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 7.5, weight: .black, design: AgentPalette.interfaceFontDesign))
                    .foregroundStyle(AgentPalette.tertiaryText)
                    .textCase(.uppercase)
                Text(value)
                    .font(.system(size: 9.5, weight: .bold, design: AgentPalette.interfaceFontDesign))
                    .foregroundStyle(AgentPalette.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 0)
        }
        .padding(8)
        .background(AgentPalette.surfaceAlt.opacity(0.10), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func memoryQuickActions(for item: ProjectMemoryItem) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 7) {
                memoryActionButton(title: primaryActionTitle(for: item), symbol: primaryActionSymbol(for: item), tint: item.tint) {
                    openMemoryItem(item)
                }

                memoryActionButton(title: "Copy Path", symbol: "doc.on.doc.fill", tint: AgentPalette.cyan) {
                    copyMemoryPath(item)
                }

                if item.hasRelatedContext {
                    memoryActionButton(title: "Related Run", symbol: "point.3.connected.trianglepath.dotted", tint: AgentPalette.lilac) {
                        revealRelatedContext(for: item)
                    }
                }

                if item.comparisonPaths != nil {
                    memoryActionButton(title: "Compare", symbol: "arrow.left.arrow.right", tint: AgentPalette.lilac) {
                        compareMemoryItem(item)
                    }
                }

                memoryActionButton(title: item.isImportant ? "Unmark" : "Important", symbol: item.isImportant ? "star.slash.fill" : "star.fill", tint: AgentPalette.warning) {
                    toggleImportant(item)
                }

                memoryActionButton(title: item.isPinned ? "Unpin" : "Pin", symbol: item.isPinned ? "pin.slash.fill" : "pin.fill", tint: AgentPalette.warning) {
                    togglePinned(item)
                }

                memoryActionButton(title: "Brief", symbol: "text.badge.plus", tint: AgentPalette.green) {
                    addToProjectBrief(item)
                }

                memoryActionButton(title: "Chat", symbol: "bubble.left.and.bubble.right.fill", tint: AgentPalette.cyan) {
                    openChat()
                }
            }
            .padding(.vertical, 1)
        }
    }

    private func memoryActionButton(title: String, symbol: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            action()
        } label: {
            Label(title, systemImage: symbol)
                .font(.system(size: 10, weight: .black, design: AgentPalette.interfaceFontDesign))
                .foregroundStyle(AgentPalette.ink)
                .padding(.horizontal, 9)
                .frame(minWidth: AgentDesign.minimumTouchTarget, minHeight: 34)
                .agentControlSurface(radius: 11, tint: tint.opacity(0.10), selected: true)
        }
        .buttonStyle(.plain)
    }

    private var artifactGallery: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 7) {
                Image(systemName: "shippingbox.fill")
                    .font(.system(size: 10, weight: .black))
                    .foregroundStyle(AgentPalette.green)
                Text("Artifact Gallery")
                    .font(.system(size: 12, weight: .black, design: AgentPalette.interfaceFontDesign))
                    .foregroundStyle(AgentPalette.ink)
                Spacer(minLength: 0)
                Text("\(artifactGalleryItems.count)")
                    .font(.system(size: 9, weight: .black, design: AgentPalette.interfaceFontDesign))
                    .foregroundStyle(AgentPalette.tertiaryText)
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 128, maximum: 180), spacing: 8)], spacing: 8) {
                ForEach(artifactGalleryItems) { item in
                    projectMemoryGalleryCard(item)
                }
            }
        }
        .padding(10)
        .background(AgentPalette.surfaceAlt.opacity(0.10), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityIdentifier("filesArtifactGallery")
    }

    private func projectMemoryGalleryCard(_ item: ProjectMemoryItem) -> some View {
        Button {
            selectedMemoryItemID = item.id
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: item.symbol)
                        .font(.system(size: 13, weight: .black))
                        .foregroundStyle(item.tint)
                        .frame(width: 30, height: 30)
                        .agentControlSurface(radius: 10, tint: item.tint.opacity(0.12), selected: true)
                    Spacer(minLength: 0)
                    if item.isFailed {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 10, weight: .black))
                            .foregroundStyle(AgentPalette.rose)
                    } else if item.isPinned {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 10, weight: .black))
                            .foregroundStyle(AgentPalette.warning)
                    }
                }

                Text(item.title)
                    .font(.system(size: 11, weight: .black, design: AgentPalette.interfaceFontDesign))
                    .foregroundStyle(AgentPalette.ink)
                    .lineLimit(2)
                    .truncationMode(.middle)

                Text(item.status)
                    .font(.system(size: 9, weight: .bold, design: AgentPalette.interfaceFontDesign))
                    .foregroundStyle(AgentPalette.secondaryText)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, minHeight: 112, alignment: .topLeading)
            .padding(10)
            .agentRowSurface(radius: 14, tint: item.tint.opacity(0.07), selected: selectedMemoryItemID == item.id)
        }
        .buttonStyle(.plain)
        .contextMenu {
            memoryContextMenu(for: item)
        }
    }

    private var memorySectionsList: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(projectMemorySections) { section in
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 7) {
                        Image(systemName: section.group.symbol)
                            .font(.system(size: 10, weight: .black))
                            .foregroundStyle(section.group.tint)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(section.group.title)
                                .font(.system(size: 12, weight: .black, design: AgentPalette.interfaceFontDesign))
                                .foregroundStyle(AgentPalette.ink)
                            Text(section.group.subtitle)
                                .font(.system(size: 9, weight: .semibold, design: AgentPalette.interfaceFontDesign))
                                .foregroundStyle(AgentPalette.tertiaryText)
                        }
                        Spacer(minLength: 0)
                        Text("\(section.items.count)")
                            .font(.system(size: 9, weight: .black, design: AgentPalette.interfaceFontDesign))
                            .foregroundStyle(AgentPalette.secondaryText)
                    }

                    VStack(spacing: 0) {
                        ForEach(Array(section.items.prefix(5).enumerated()), id: \.element.id) { index, item in
                            projectMemoryRow(item)
                            if index < min(section.items.count, 5) - 1 {
                                Divider()
                                    .overlay(AgentPalette.border.opacity(0.36))
                                    .padding(.leading, 42)
                            }
                        }

                        if section.items.count > 5 {
                            Text("+\(section.items.count - 5) more")
                                .font(.system(size: 9, weight: .black, design: AgentPalette.interfaceFontDesign))
                                .foregroundStyle(section.group.tint)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.top, 7)
                        }
                    }
                }
                .padding(10)
                .background(section.group.tint.opacity(0.055), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
        }
    }

    private func projectMemoryRow(_ item: ProjectMemoryItem) -> some View {
        Button {
            selectedMemoryItemID = item.id
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: item.symbol)
                    .font(.system(size: 12, weight: .black))
                    .foregroundStyle(item.tint)
                    .frame(width: 32, height: 32)
                    .background(item.tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(item.title)
                            .font(.system(size: 12, weight: .black, design: AgentPalette.interfaceFontDesign))
                            .foregroundStyle(AgentPalette.ink)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if item.isImportant {
                            Image(systemName: "star.fill")
                                .font(.system(size: 8, weight: .black))
                                .foregroundStyle(AgentPalette.warning)
                        }
                    }
                    Text(item.metadata)
                        .font(.system(size: 9.5, weight: .semibold, design: AgentPalette.interfaceFontDesign))
                        .foregroundStyle(AgentPalette.secondaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(item.detail)
                        .font(.system(size: 9, weight: .semibold, design: AgentPalette.interfaceFontDesign))
                        .foregroundStyle(AgentPalette.tertiaryText)
                        .lineLimit(2)
                }

                Spacer(minLength: 0)

                VStack(alignment: .trailing, spacing: 6) {
                    Text(item.status)
                        .font(.system(size: 8, weight: .black, design: AgentPalette.interfaceFontDesign))
                        .foregroundStyle(item.tint)
                        .lineLimit(1)
                        .padding(.horizontal, 6)
                        .frame(height: 18)
                        .agentControlSurface(radius: 6, tint: item.tint.opacity(0.10), selected: true)

                    Image(systemName: selectedMemoryItemID == item.id ? "checkmark.circle.fill" : "info.circle")
                        .font(.system(size: 12, weight: .black))
                        .foregroundStyle(selectedMemoryItemID == item.id ? AgentPalette.green : AgentPalette.secondaryText)
                }
            }
            .padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            memoryContextMenu(for: item)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(item.title). \(item.status). \(item.detail)")
        .accessibilityIdentifier("filesMemoryRow-\(item.id)")
    }

    @ViewBuilder
    private func memoryContextMenu(for item: ProjectMemoryItem) -> some View {
        Button {
            openMemoryItem(item)
        } label: {
            Label(primaryActionTitle(for: item), systemImage: primaryActionSymbol(for: item))
        }
        Button {
            copyMemoryPath(item)
        } label: {
            Label("Copy Path", systemImage: "doc.on.doc")
        }
        if item.hasRelatedContext {
            Button {
                revealRelatedContext(for: item)
            } label: {
                Label("Reveal Related Run", systemImage: "point.3.connected.trianglepath.dotted")
            }
        }
        if item.comparisonPaths != nil {
            Button {
                compareMemoryItem(item)
            } label: {
                Label("Compare", systemImage: "arrow.left.arrow.right")
            }
        }
        Button {
            toggleImportant(item)
        } label: {
            Label(item.isImportant ? "Unmark Important" : "Mark Important", systemImage: item.isImportant ? "star.slash" : "star")
        }
        Button {
            togglePinned(item)
        } label: {
            Label(item.isPinned ? "Unpin" : "Pin", systemImage: item.isPinned ? "pin.slash" : "pin")
        }
    }

    private func memoryTag(_ title: String, symbol: String, tint: Color) -> some View {
        Label(title, systemImage: symbol)
            .font(.system(size: 9, weight: .black, design: AgentPalette.interfaceFontDesign))
            .foregroundStyle(tint)
            .padding(.horizontal, 7)
            .frame(height: 22)
            .agentControlSurface(radius: 8, tint: tint.opacity(0.10), selected: true)
    }

    private var fileStats: some View {
        HStack(spacing: 10) {
            MenuStatChip(title: "Folders", value: "\(cachedStats.folderCount)", symbol: "folder.fill", tint: AgentPalette.cyan)
            MenuStatChip(title: "Files", value: "\(cachedStats.fileCount)", symbol: "doc.fill", tint: AgentPalette.lilac)
            MenuStatChip(title: "Size", value: cachedStats.totalBytesText, symbol: "internaldrive.fill", tint: AgentPalette.storageAccent)
        }
    }

    private var actionBar: some View {
        HStack(spacing: 8) {
            IconGlassButton(symbol: "chevron.up", accessibilityLabel: "Go up", accessibilityIdentifier: "filesGoUpButton") {
                goUp()
            }
            .disabled(currentPath.isEmpty)

            IconGlassButton(
                symbol: isGridLayout ? "list.bullet" : "square.grid.2x2",
                accessibilityLabel: "Toggle file layout",
                accessibilityIdentifier: "filesLayoutToggle"
            ) {
                let impact = UIImpactFeedbackGenerator(style: .light)
                impact.impactOccurred()
                let toggle = {
                    isGridLayout.toggle()
                }
                if items.count > 120 {
                    toggle()
                } else {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                        toggle()
                    }
                }
            }

            IconGlassButton(symbol: "magnifyingglass", accessibilityLabel: "Search files", accessibilityIdentifier: "filesSearchButton") {
                showingSearch = true
            }

            Menu {
                ForEach(workspaces, id: \.self) { ws in
                    Button {
                        switchWorkspace(to: ws)
                    } label: {
                        HStack {
                            Text(ws)
                            if ws == runtime.workspace.workspaceName {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }

                Divider()

                Button {
                    showingCreateWorkspace = true
                } label: {
                    Label("New Workspace...", systemImage: "plus.rectangle.on.folder")
                }

                Button {
                    exportWorkspace()
                } label: {
                    Label("Export Workspace (ZIP)", systemImage: "square.and.arrow.up")
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "square.grid.2x2.fill")
                        .font(.caption)
                        .foregroundStyle(AgentPalette.cyan)
                    Text(runtime.workspace.workspaceName)
                        .font(.caption.weight(.bold))
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.caption)
                        .foregroundStyle(AgentPalette.secondaryText)
                }
                .foregroundStyle(AgentPalette.ink)
                .padding(.horizontal, 12)
                .frame(minHeight: AgentDesign.minimumTouchTarget)
                .agentControlSurface(radius: 14, tint: AgentPalette.cyan)
            }
            .accessibilityLabel("Switch workspace, \(runtime.workspace.workspaceName)")
            .accessibilityIdentifier("filesWorkspaceMenu")

            Spacer(minLength: 0)

            IconGlassButton(symbol: "plus", accessibilityLabel: "Create file", accessibilityIdentifier: "filesCreateFileButton", tint: AgentPalette.green) {
                showingCreate = true
            }
        }
    }

    private var breadcrumbs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                Button {
                    currentPath = ""
                    reload()
                } label: {
                    Text("Home")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(currentPath.isEmpty ? AgentPalette.cyan : AgentPalette.secondaryText)
                        .padding(.horizontal, 10)
                        .frame(minWidth: AgentDesign.minimumTouchTarget, minHeight: AgentDesign.minimumTouchTarget)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("filesBreadcrumb-home")
                
                let parts = currentPath.components(separatedBy: "/").filter { !$0.isEmpty }
                ForEach(Array(parts.enumerated()), id: \.offset) { idx, part in
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(AgentPalette.tertiaryText)
                    
                    Button {
                        let targetPath = parts.prefix(idx + 1).joined(separator: "/")
                        currentPath = targetPath
                        reload()
                    } label: {
                        Text(part)
                            .font(.caption.weight(.bold))
                            .foregroundStyle(idx == parts.count - 1 ? AgentPalette.cyan : AgentPalette.secondaryText)
                            .lineLimit(1)
                            .padding(.horizontal, 10)
                            .frame(minWidth: AgentDesign.minimumTouchTarget, minHeight: AgentDesign.minimumTouchTarget)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("filesBreadcrumb-\(idx)-\(part)")
                }
                
                if !items.isEmpty {
                    Spacer()
                    Text("\(items.count) item\(items.count == 1 ? "" : "s")")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(AgentPalette.secondaryText)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .agentControlSurface(radius: 6)
                }
            }
            .padding(.horizontal)
        }
    }

    private var listLayout: some View {
        LazyVStack(spacing: 8) {
            ForEach(items) { row in
                HStack(spacing: 10) {
                    Button {
                        open(row.item)
                    } label: {
                        HStack(spacing: 14) {
                            Image(systemName: row.visualKind.symbolName)
                                .font(.title3)
                                .foregroundStyle(row.visualKind.tint)
                                .frame(width: 36, height: 36)
                                .agentGlass(radius: 10, interactive: false, tint: row.visualKind.tint.opacity(0.12))

                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 6) {
                                    Text(row.item.name)
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(AgentPalette.ink)
                                        .lineLimit(1)
                                        .truncationMode(.middle)

                                    if row.isRecent {
                                        Circle()
                                            .fill(AgentPalette.cyan)
                                            .frame(width: 6, height: 6)
                                            .shadow(color: AgentPalette.cyan, radius: 3)
                                    }
                                }

                                HStack(spacing: 6) {
                                    Text(row.kindText)
                                        .font(.caption2)
                                        .foregroundStyle(AgentPalette.secondaryText)
                                        .lineLimit(1)

                                    Text(row.modifiedText)
                                        .font(.caption2)
                                        .foregroundStyle(AgentPalette.tertiaryText)
                                        .lineLimit(1)
                                        .truncationMode(.tail)

                                    if let extensionText = row.extensionText {
                                        Text(extensionText)
                                            .font(.system(size: 7, weight: .bold, design: AgentPalette.interfaceFontDesign))
                                            .foregroundStyle(row.visualKind.tint)
                                            .lineLimit(1)
                                            .fixedSize(horizontal: true, vertical: false)
                                            .padding(.horizontal, 4)
                                            .padding(.vertical, 1)
                                            .agentControlSurface(radius: 4, tint: row.visualKind.tint, selected: true)
                                    }

                                    if row.isPreviewable {
                                        Label("Preview", systemImage: "play.fill")
                                            .font(.system(size: 7, weight: .black, design: AgentPalette.interfaceFontDesign))
                                            .foregroundStyle(AgentPalette.green)
                                            .labelStyle(.titleAndIcon)
                                            .lineLimit(1)
                                            .fixedSize(horizontal: true, vertical: false)
                                            .padding(.horizontal, 5)
                                            .frame(height: 16)
                                            .agentControlSurface(radius: 5, tint: AgentPalette.green.opacity(0.12), selected: true)
                                    }
                                }
                            }

                            Spacer(minLength: 8)

                            Image(systemName: row.item.isDirectory ? "chevron.right" : "square.and.pencil")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(AgentPalette.secondaryText)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    fileActionMenu(for: row.item)
                }
                .padding(12)
                .agentRowSurface(radius: 16, tint: row.visualKind.tint)
                .contextMenu {
                    contextMenuActions(for: row.item)
                }
            }
        }
        .padding(.horizontal)
    }

    private var gridLayout: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 100, maximum: 130), spacing: 12)], spacing: 12) {
            ForEach(items) { row in
                Button {
                    open(row.item)
                } label: {
                    VStack(spacing: 8) {
                        Image(systemName: row.visualKind.symbolName)
                            .font(.title2)
                            .foregroundStyle(row.visualKind.tint)
                            .frame(width: 44, height: 44)
                            .agentGlass(radius: 13, interactive: false, tint: row.visualKind.tint.opacity(0.12))
                        
                        HStack(spacing: 4) {
                            Text(row.item.name)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(AgentPalette.ink)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            
                            if row.isRecent {
                                Circle()
                                    .fill(AgentPalette.cyan)
                                    .frame(width: 5, height: 5)
                                    .shadow(color: AgentPalette.cyan, radius: 2)
                            }
                        }
                        
                        Text(row.kindText)
                            .font(.system(size: 9))
                            .foregroundStyle(AgentPalette.secondaryText)

                        if row.isPreviewable || row.isRecent {
                            Label(row.isPreviewable ? "Previewable" : "Fresh", systemImage: row.isPreviewable ? "play.fill" : "sparkle")
                                .font(.system(size: 7.5, weight: .black, design: AgentPalette.interfaceFontDesign))
                                .foregroundStyle(row.isPreviewable ? AgentPalette.green : AgentPalette.cyan)
                                .lineLimit(1)
                                .padding(.horizontal, 6)
                                .frame(height: 18)
                                .agentControlSurface(radius: 6, tint: (row.isPreviewable ? AgentPalette.green : AgentPalette.cyan).opacity(0.12), selected: true)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .agentRowSurface(radius: 18, tint: row.visualKind.tint)
                }
                .buttonStyle(.plain)
                .overlay(alignment: .topTrailing) {
                    fileActionMenu(for: row.item)
                        .padding(6)
                }
                .contextMenu {
                    contextMenuActions(for: row.item)
                }
            }
        }
        .padding(.horizontal)
    }

    private func fileActionMenu(for item: FileItem) -> some View {
        HStack(spacing: 4) {
            if canPreview(item) {
                filePrimaryActionButton(
                    symbol: "play.rectangle.fill",
                    label: "Preview \(item.name)",
                    identifier: fileActionIdentifier(prefix: "filePreview", relativePath: item.relativePath),
                    tint: AgentPalette.green
                ) {
                    preview(item)
                }
            } else if !item.isDirectory {
                filePrimaryActionButton(
                    symbol: "square.and.pencil",
                    label: "Edit \(item.name)",
                    identifier: fileActionIdentifier(prefix: "fileEdit", relativePath: item.relativePath),
                    tint: AgentPalette.cyan
                ) {
                    editFile(item)
                }
            }

            Menu {
                if canPreview(item) {
                    Button {
                        preview(item)
                    } label: {
                        Label("Preview", systemImage: "play.rectangle.fill")
                    }
                }

                if !item.isDirectory {
                    Button {
                        editFile(item)
                    } label: {
                        Label("Edit", systemImage: "square.and.pencil")
                    }
                }

                if !item.isDirectory {
                    Button {
                        duplicateFile(item)
                    } label: {
                        Label("Duplicate", systemImage: "plus.square.on.square")
                    }
                }

                Button(role: .destructive) {
                    pendingDeleteItem = item
                } label: {
                    Label(item.isDirectory ? "Delete Folder" : "Delete File", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.caption.weight(.black))
                    .foregroundStyle(AgentPalette.secondaryText)
                    .frame(width: 44, height: 44)
                    .agentControlSurface(radius: 13, tint: AgentPalette.secondaryText.opacity(0.05), selected: false)
            }
            .accessibilityLabel("More actions for \(item.name)")
            .accessibilityIdentifier(fileActionIdentifier(prefix: "fileMoreActions", relativePath: item.relativePath))
            .disabled(fileActionTask != nil)
            .opacity(fileActionTask == nil ? 1 : 0.42)
        }
    }

    private func filePrimaryActionButton(
        symbol: String,
        label: String,
        identifier: String,
        tint: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.caption.weight(.black))
                .foregroundStyle(tint)
                .frame(width: 44, height: 44)
                .agentControlSurface(radius: 13, tint: tint.opacity(0.12), selected: true)
        }
        .accessibilityLabel(label)
        .accessibilityIdentifier(identifier)
        .disabled(fileActionTask != nil)
        .opacity(fileActionTask == nil ? 1 : 0.42)
    }

    @ViewBuilder
    private func contextMenuActions(for item: FileItem) -> some View {
        if canPreview(item) {
            Button {
                preview(item)
            } label: {
                Label("Preview Artifact", systemImage: "play.rectangle")
            }
        }

        if !item.isDirectory {
            Button {
                editFile(item)
            } label: {
                Label("Edit", systemImage: "square.and.pencil")
            }

            Button {
                duplicateFile(item)
            } label: {
                Label("Duplicate", systemImage: "plus.square.on.square")
            }
        }

        Button(role: .destructive) {
            pendingDeleteItem = item
        } label: {
            Label("Delete", systemImage: "trash")
        }
    }

    private func primaryActionTitle(for item: ProjectMemoryItem) -> String {
        if item.isDirectory { return "Open" }
        if item.isPreviewable { return "Preview" }
        if item.isEditable { return "Edit" }
        return "Open"
    }

    private func primaryActionSymbol(for item: ProjectMemoryItem) -> String {
        if item.isDirectory { return "folder.fill" }
        if item.isPreviewable { return "play.rectangle.fill" }
        if item.isEditable { return "square.and.pencil" }
        return "arrow.up.right.square.fill"
    }

    private func openMemoryItem(_ item: ProjectMemoryItem) {
        selectedMemoryItemID = item.id
        openWorkspaceEvidencePath(item.primaryPath)
    }

    private func copyMemoryPath(_ item: ProjectMemoryItem) {
        UIPasteboard.general.string = item.primaryPath
        showTransientNotice("Copied \(readableEvidencePath(item.primaryPath))")
    }

    private func toggleImportant(_ item: ProjectMemoryItem) {
        let key = item.primaryPath
        if importantMemoryPaths.contains(key) {
            importantMemoryPaths.remove(key)
            showTransientNotice("Unmarked important")
        } else {
            importantMemoryPaths.insert(key)
            showTransientNotice("Marked important")
        }
        saveMemoryFlags()
    }

    private func togglePinned(_ item: ProjectMemoryItem) {
        let key = item.primaryPath
        if pinnedMemoryPaths.contains(key) {
            pinnedMemoryPaths.remove(key)
            showTransientNotice("Unpinned")
        } else {
            pinnedMemoryPaths.insert(key)
            showTransientNotice("Pinned to memory")
        }
        saveMemoryFlags()
    }

    private func loadMemoryFlags() {
        importantMemoryPaths = Self.loadPathSet(key: "\(memoryPreferencePrefix).important")
        pinnedMemoryPaths = Self.loadPathSet(key: "\(memoryPreferencePrefix).pinned")
    }

    private func saveMemoryFlags() {
        Self.savePathSet(importantMemoryPaths, key: "\(memoryPreferencePrefix).important")
        Self.savePathSet(pinnedMemoryPaths, key: "\(memoryPreferencePrefix).pinned")
    }

    private static func loadPathSet(key: String) -> Set<String> {
        guard let data = UserDefaults.standard.data(forKey: key),
              let values = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        return Set(values)
    }

    private static func savePathSet(_ values: Set<String>, key: String) {
        guard let data = try? JSONEncoder().encode(values.sorted()) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    private func addToProjectBrief(_ item: ProjectMemoryItem) {
        let path = item.primaryPath
        guard !project.mission.localizedCaseInsensitiveContains(path) else {
            showTransientNotice("Already in project brief")
            return
        }

        let line = "- \(item.title) (\(path)): \(item.detail)"
        let trimmedMission = project.mission.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedMission.localizedCaseInsensitiveContains("Project Memory:") {
            project.mission = "\(trimmedMission)\n\(line)"
        } else if trimmedMission.isEmpty {
            project.mission = "Project Memory:\n\(line)"
        } else {
            project.mission = "\(trimmedMission)\n\nProject Memory:\n\(line)"
        }
        project.updatedAt = Date()
        project.lastActivityAt = Date()
        ProjectEventRecorder.record(
            project: project,
            kind: .agentProofCreated,
            title: "Project brief updated",
            detail: path,
            severity: .info,
            sourceType: .workspace,
            metadata: ["path": path, "source": "filesWorkbench"],
            context: modelContext
        )
        if saveFileEvidence(failureMessage: "Added \(readableEvidencePath(path)) to the project brief, but NovaForge could not save it") {
            showTransientNotice("Added to project brief")
        }
    }

    private func compareMemoryItem(_ item: ProjectMemoryItem) {
        guard let paths = item.comparisonPaths else { return }
        do {
            let source = try runtime.workspace.read(paths.source)
            let destination = try runtime.workspace.read(paths.destination)
            let comparison = Self.lineDiff(source: source, destination: destination)
            comparisonDraft = FileComparisonDraft(
                title: item.title,
                sourcePath: paths.source,
                destinationPath: paths.destination,
                summary: comparison.summary,
                diffText: comparison.diffText
            )
        } catch {
            comparisonDraft = FileComparisonDraft(
                title: item.title,
                sourcePath: paths.source,
                destinationPath: paths.destination,
                summary: "Comparison unavailable",
                diffText: error.localizedDescription
            )
        }
    }

    private static func lineDiff(source: String, destination: String) -> (summary: String, diffText: String) {
        let sourceLines = source.components(separatedBy: .newlines)
        let destinationLines = destination.components(separatedBy: .newlines)
        let maxCount = max(sourceLines.count, destinationLines.count)
        var changed = 0
        var rows: [String] = []
        let cap = 140

        for index in 0..<maxCount {
            let left = index < sourceLines.count ? sourceLines[index] : nil
            let right = index < destinationLines.count ? destinationLines[index] : nil
            guard left != right else { continue }
            changed += 1
            if rows.count < cap {
                rows.append("@@ line \(index + 1)")
                if let left { rows.append("- \(left)") }
                if let right { rows.append("+ \(right)") }
            }
        }

        if changed == 0 {
            return ("No textual differences", "The compared files match.")
        }
        if changed > cap / 3 {
            rows.append("... diff capped after \(cap) lines. Open both files for full review.")
        }
        return ("\(changed) changed line\(changed == 1 ? "" : "s")", rows.joined(separator: "\n"))
    }

    private func revealRelatedContext(for item: ProjectMemoryItem) {
        if let idString = item.sourceToolRunIDString,
           let id = UUID(uuidString: idString),
           let run = project.toolRuns.first(where: { $0.id == id }) {
            relatedContextDraft = FileRelatedContextDraft(
                title: run.name,
                subtitle: "Tool run · \(run.status.rawValue)",
                detail: Self.compactDetail(run.output.isEmpty ? run.argumentsJSON : run.output),
                symbol: run.status == .failed ? "xmark.octagon.fill" : "wrench.and.screwdriver.fill",
                tint: run.status == .failed ? AgentPalette.rose : AgentPalette.cyan
            )
            return
        }

        if let idString = item.sourceTerminalCommandIDString,
           let id = UUID(uuidString: idString),
           let command = project.terminalCommands.first(where: { $0.id == id }) {
            relatedContextDraft = FileRelatedContextDraft(
                title: command.command,
                subtitle: "Terminal command · \(command.status.rawValue)",
                detail: Self.compactDetail(command.output),
                symbol: "terminal.fill",
                tint: command.status == .failed ? AgentPalette.rose : AgentPalette.indigo
            )
            return
        }

        if let idString = item.sourceEventIDString,
           let id = UUID(uuidString: idString),
           let event = project.events.first(where: { $0.id == id }) {
            relatedContextDraft = FileRelatedContextDraft(
                title: event.title,
                subtitle: "Project event · \(event.severity.rawValue)",
                detail: event.detail.isEmpty ? "No additional event detail." : event.detail,
                symbol: "timeline.selection",
                tint: AgentPalette.green
            )
            return
        }

        relatedContextDraft = FileRelatedContextDraft(
            title: item.title,
            subtitle: "Related context unavailable",
            detail: "The originating run or event was not found in current project memory.",
            symbol: "questionmark.folder.fill",
            tint: AgentPalette.secondaryText
        )
    }

    private static func compactDetail(_ text: String, limit: Int = 1_800) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "No output captured." }
        guard trimmed.count > limit else { return trimmed }
        return String(trimmed.prefix(limit - 1)) + "..."
    }

    private func showTransientNotice(_ message: String) {
        withAnimation(.spring(response: 0.24, dampingFraction: 0.78)) {
            transientNotice = message
        }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(1_600))
            guard transientNotice == message else { return }
            withAnimation(.easeOut(duration: 0.18)) {
                transientNotice = nil
            }
        }
    }

    private func deleteFile(_ item: FileItem) {
        guard beginFileAction("Deleting \(item.name)…") else { return }
        let impact = UIImpactFeedbackGenerator(style: .medium)
        impact.impactOccurred()
        let workspace = runtime.workspace
        let deletedKind = item.isDirectory ? "folder" : "file"
        let deletedPath = item.relativePath
        withAnimation(.smooth(duration: 0.16)) {
            items.removeAll { $0.item.relativePath == deletedPath }
        }
        fileActionTask = Task.detached(priority: .userInitiated) {
            do {
                try Task.checkCancellation()
                try workspace.delete(deletedPath)
                try Task.checkCancellation()
            } catch {
                await MainActor.run {
                    if !(error is CancellationError) {
                        fileActionError = "Could not delete \(deletedKind) \(item.name): \(error.localizedDescription)"
                    }
                    finishFileAction()
                    reload()
                }
                return
            }
            await MainActor.run {
                guard !Task.isCancelled else {
                    finishFileAction()
                    return
                }
                runtime.noteWorkspaceChanged()
                ProjectEventRecorder.recordFileChange(
                    project: project,
                    action: item.isDirectory ? "Deleted folder" : "Deleted file",
                    path: item.relativePath,
                    context: modelContext
                )
                saveFileEvidence(
                    failureMessage: "Deleted \(deletedKind) \(item.name), but NovaForge could not save the project proof record"
                )
                finishFileAction()
                reload()
            }
        }
    }

    private func duplicateFile(_ item: FileItem) {
        guard !item.isDirectory else { return }
        guard beginFileAction("Duplicating \(item.name)…") else { return }
        let impact = UIImpactFeedbackGenerator(style: .light)
        impact.impactOccurred()
        let workspace = runtime.workspace
        let path = item.relativePath
        let name = item.name
        fileActionTask = Task.detached(priority: .userInitiated) {
            let destination: String
            do {
                try Task.checkCancellation()
                destination = try Self.nextDuplicatePath(for: item, in: workspace)
                try workspace.copy(from: path, to: destination)
                try Task.checkCancellation()
            } catch {
                await MainActor.run {
                    if !(error is CancellationError) {
                        fileActionError = "Could not duplicate \(name): \(error.localizedDescription)"
                    }
                    finishFileAction()
                }
                return
            }
            await MainActor.run {
                guard !Task.isCancelled else {
                    finishFileAction()
                    return
                }
                runtime.noteWorkspaceChanged()
                ProjectEventRecorder.recordFileChange(
                    project: project,
                    action: "Duplicated file",
                    path: "\(path) -> \(destination)",
                    context: modelContext
                )
                saveFileEvidence(
                    failureMessage: "Duplicated \(name), but NovaForge could not save the project proof record"
                )
                finishFileAction()
                reload()
            }
        }
    }

    private func beginFileAction(_ status: String) -> Bool {
        guard fileActionTask == nil else {
            fileActionError = "Finish the current file action before starting another one."
            return false
        }
        fileActionStatus = status
        return true
    }

    private func finishFileAction() {
        fileActionTask = nil
        fileActionStatus = nil
    }

    @discardableResult
    private func saveFileEvidence(failureMessage: String) -> Bool {
        do {
            try modelContext.save()
            return true
        } catch {
            modelContext.rollback()
            fileActionError = "\(failureMessage): \(error.localizedDescription)"
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            return false
        }
    }

    private func fileActionIdentifier(prefix: String, relativePath: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let sanitized = relativePath.unicodeScalars.map { scalar in
            allowed.contains(scalar) ? String(scalar) : "-"
        }.joined()
        return "\(prefix)-\(sanitized)"
    }

    private func deleteConfirmationDetail(for item: FileItem) -> String {
        if item.isDirectory {
            return "\(item.relativePath) and everything inside it will be removed from the NovaForge workspace. This keeps accidental menu taps from destroying work."
        }
        return "\(item.relativePath) will be removed from the NovaForge workspace. This keeps accidental menu taps from destroying work."
    }

    nonisolated private static func nextDuplicatePath(for item: FileItem, in workspace: SandboxWorkspace) throws -> String {
        let sourcePath = item.relativePath
        let parts = sourcePath.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        let parent = parts.dropLast().joined(separator: "/")
        let parentPrefix = parent.isEmpty ? "" : "\(parent)/"
        let sourceURL = URL(fileURLWithPath: item.name)
        let base = sourceURL.deletingPathExtension().lastPathComponent
        let ext = sourceURL.pathExtension

        for index in 1...99 {
            let suffix = index == 1 ? "_copy" : "_copy \(index)"
            let newName = ext.isEmpty ? "\(base)\(suffix)" : "\(base)\(suffix).\(ext)"
            let candidate = "\(parentPrefix)\(newName)"
            if !FileManager.default.fileExists(atPath: (try workspace.resolve(candidate)).path) {
                return candidate
            }
        }

        throw SandboxError.invalidArguments
    }

    private nonisolated static func byteCountString(_ bytes: Int64) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        let kb = Double(bytes) / 1024.0
        if kb < 1024 { return String(format: "%.1f KB", kb) }
        let mb = kb / 1024.0
        return String(format: "%.1f MB", mb)
    }

    private func reload() {
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
                    fileLoadError = message
                    reloadTask = nil
                }
            }
        }
    }

    private func reloadWorkspaces() {
        workspaces = SandboxWorkspace.listWorkspaces()
    }

    @discardableResult
    private func switchWorkspace(to name: String) -> Bool {
        let safeName = SandboxWorkspace.sanitizedWorkspaceName(name)
        let projectWorkspaceWillChange = project.workspaceName != safeName
        if projectWorkspaceWillChange {
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
        do {
            try FilesWorkspacePersistence.persistProjectWorkspaceSelection(
                safeName,
                project: project,
                settings: settings,
                save: { try modelContext.save() }
            )
        } catch {
            modelContext.rollback()
            workspaceSaveError = "Could not switch to \(safeName): \(error.localizedDescription)"
            return false
        }
        runtime.switchWorkspace(to: safeName)
        currentPath = ""
        reload()
        reloadWorkspaces()
        return true
    }

    private func createWorkspace() {
        let name = SandboxWorkspace.sanitizedWorkspaceName(newWorkspaceName)
        guard !name.isEmpty else { return }
        if switchWorkspace(to: name) {
            newWorkspaceName = ""
        }
    }

    private func open(_ item: FileItem) {
        if item.isDirectory {
            withAnimation(.smooth(duration: 0.3)) {
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

    private func preview(_ item: FileItem) {
        previewArtifactPath(item.relativePath, displayName: item.name)
    }

    private func editFile(_ item: FileItem) {
        guard !item.isDirectory else { return }
        editingTarget = FileEditTarget(item: item)
    }

    private func previewArtifactPath(_ path: String, displayName: String? = nil) {
        let artifact = WorkspaceArtifact(path: path)
        ProjectEventRecorder.noteArtifactPreview(
            artifact,
            project: project,
            context: modelContext
        )
        saveFileEvidence(
            failureMessage: "Opened preview for \(displayName ?? readableEvidencePath(path)), but NovaForge could not save the artifact proof record"
        )
        previewArtifact = artifact
    }

    private func openWorkspaceEvidencePath(_ path: String) {
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

    private func openDebugArtifactPreviewIfRequested() {
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
                        project: project,
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

    private func canPreview(_ item: FileItem) -> Bool {
        guard !item.isDirectory else { return false }
        return canPreviewPath(item.relativePath)
    }

    private func canPreviewPath(_ path: String) -> Bool {
        WorkspaceArtifact(path: path).isReadablePreviewArtifact
    }

    private func readableEvidencePath(_ path: String) -> String {
        let name = URL(fileURLWithPath: path).lastPathComponent
        return name.isEmpty ? path : name
    }

    private func parentPath(for path: String) -> String {
        path
            .split(separator: "/", omittingEmptySubsequences: false)
            .dropLast()
            .joined(separator: "/")
    }

    private func goUp() {
        guard !currentPath.isEmpty else { return }
        currentPath = currentPath.components(separatedBy: "/").dropLast().joined(separator: "/")
        reload()
    }

    private func createFile() {
        guard !newFileName.isEmpty else { return }
        let path = currentPath.isEmpty ? newFileName : "\(currentPath)/\(newFileName)"
        do {
            try runtime.workspace.write(path, contents: "")
        } catch {
            fileActionError = "Could not create \(newFileName): \(error.localizedDescription)"
            return
        }
        runtime.noteWorkspaceChanged()
        ProjectEventRecorder.recordFileChange(
            project: project,
            action: "Created file",
            path: path,
            context: modelContext
        )
        saveFileEvidence(
            failureMessage: "Created \(newFileName), but NovaForge could not save the project proof record"
        )
        newFileName = ""
        reload()
    }
    
    private var searchSheet: some View {
        ZStack {
            AgentBackground()
            VStack(alignment: .leading, spacing: 18) {
                HeaderView(title: "Workspace Finder", subtitle: "Full-text search in \(runtime.workspace.workspaceName)", symbol: "doc.text.magnifyingglass")
                
                HStack(spacing: 8) {
                    TextField("Search term...", text: $searchQuery)
                        .textFieldStyle(.plain)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.none)
                        .focused($searchFocused)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 12)
                        .frame(minHeight: AgentDesign.minimumTouchTarget + 8)
                        .contentShape(Rectangle())
                        .agentControlSurface(radius: 12, tint: AgentPalette.cyan)
                        .onSubmit(runSearch)
                        .accessibilityIdentifier("filesSearchField")
                    
                    Button {
                        runSearch()
                    } label: {
                        ZStack {
                            Color.clear
                            Label("Search", systemImage: "magnifyingglass")
                                .labelStyle(.iconOnly)
                        }
                        .frame(width: AgentDesign.minimumTouchTarget, height: AgentDesign.minimumTouchTarget)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSearching)
                    .accessibilityIdentifier("filesSearchRun")
                }
                
                if isSearching {
                    AgentCenteredStateView(
                        title: "Searching workspace",
                        detail: "Scanning files safely, skipping oversized generated logs.",
                        symbol: "doc.text.magnifyingglass",
                        tint: AgentPalette.cyan,
                        isLoading: true
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if !hasSearchedFiles {
                    FileSearchPrompt()
                } else if let searchErrorMessage {
                    AgentCenteredStateView(
                        title: "Search failed",
                        detail: searchErrorMessage,
                        symbol: "exclamationmark.triangle",
                        tint: AgentPalette.rose
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if searchResults.isEmpty {
                    AgentCenteredStateView(
                        title: "No matches for \"\(lastSearchQuery)\"",
                        detail: "Try a symbol, file name, or short phrase from the workspace.",
                        symbol: "magnifyingglass.circle",
                        tint: AgentPalette.secondaryText
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(searchSummaryText)
                            .font(.caption.weight(.bold))
                            .foregroundStyle(AgentPalette.secondaryText)
                            .accessibilityIdentifier("filesSearchSummary")
                        if searchStats.scannedFiles > 0 || searchStats.skippedLargeFiles > 0 || searchStats.skippedUnsafePaths > 0 || searchStats.capped {
                            Text(searchDetailText)
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(AgentPalette.tertiaryText)
                                .accessibilityIdentifier("filesSearchDetail")
                        }

                        ScrollView {
                            LazyVStack(spacing: 8) {
                                ForEach(searchResults) { result in
                                    FileSearchResultRow(
                                        result: result,
                                        query: lastSearchQuery,
                                        open: { openResult(result) }
                                    )
                                }
                            }
                        }
                    }
                    .scrollDismissesKeyboard(.interactively)
                }
                
                Button {
                    dismissSearchKeyboard()
                    showingSearch = false
                } label: {
                    Text("Close")
                        .frame(maxWidth: .infinity, minHeight: AgentDesign.minimumTouchTarget)
                }
                .buttonStyle(.bordered)
                .contentShape(Rectangle())
                .accessibilityIdentifier("filesSearchClose")
            }
            .padding()
        }
    }

    private var searchSummaryText: String {
        let countText = searchStats.capped && searchResults.count >= searchResultLimit
            ? "\(searchResultLimit)+"
            : "\(searchResults.count)"
        return "\(countText) match\(searchResults.count == 1 ? "" : "es") for \"\(lastSearchQuery)\""
    }

    private var searchDetailText: String {
        var parts = ["\(searchStats.scannedFiles) files scanned", "\(searchStats.searchedDirectories) folders"]
        if searchStats.skippedLargeFiles > 0 {
            parts.append("\(searchStats.skippedLargeFiles) huge skipped")
        }
        if searchStats.skippedUnsafePaths > 0 {
            parts.append("\(searchStats.skippedUnsafePaths) unsafe links skipped")
        }
        if searchStats.capped {
            parts.append("capped for smoothness")
        }
        return parts.joined(separator: " · ")
    }
    
    private func runSearch() {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }

        dismissSearchKeyboard()
        isSearching = true
        searchErrorMessage = nil
        searchStats = FileSearchStats()
        let searchID = UUID()
        activeSearchID = searchID
        searchTask?.cancel()
        let workspace = runtime.workspace
        let resultLimit = searchResultLimit
        searchTask = Task.detached(priority: .userInitiated) {
            do {
                let report = try workspace.searchMatches(
                    query: query,
                    maxFilesScanned: 900,
                    maxDirectories: 180,
                    maxMatches: resultLimit,
                    maxReadableFileBytes: 750_000
                )
                try Task.checkCancellation()
                let results = report.matches.map { match in
                    SearchResultItem(
                        fileName: match.fileName,
                        relativePath: match.relativePath,
                        lineNumber: match.lineNumber,
                        lineContent: match.lineContent
                    )
                }
                let stats = FileSearchStats(
                    scannedFiles: report.filesScanned,
                    skippedLargeFiles: report.skippedLargeFiles,
                    skippedUnsafePaths: report.skippedUnsafePaths,
                    searchedDirectories: report.searchedDirectories,
                    capped: report.capped
                )
                await MainActor.run {
                    guard activeSearchID == searchID else { return }
                    searchResults = results
                    searchStats = stats
                    hasSearchedFiles = true
                    lastSearchQuery = query
                    dismissSearchKeyboard()
                    isSearching = false
                    searchTask = nil
                }
            } catch is CancellationError {
                await MainActor.run {
                    guard activeSearchID == searchID else { return }
                    isSearching = false
                    searchTask = nil
                }
            } catch {
                await MainActor.run {
                    guard activeSearchID == searchID else { return }
                    searchResults = []
                    searchStats = FileSearchStats()
                    hasSearchedFiles = true
                    lastSearchQuery = query
                    searchErrorMessage = error.localizedDescription
                    dismissSearchKeyboard()
                    isSearching = false
                    searchTask = nil
                }
            }
        }
    }

    private func cancelSearch() {
        activeSearchID = nil
        searchTask?.cancel()
        searchTask = nil
        isSearching = false
    }

    private func openResult(_ result: SearchResultItem) {
        let item = FileItem(
            name: result.fileName,
            relativePath: result.relativePath,
            isDirectory: false,
            byteCount: 0,
            modifiedAt: nil
        )
        pendingSearchOpenTarget = FileEditTarget(item: item, focusedLineNumber: result.lineNumber)
        dismissSearchKeyboard()
        showingSearch = false
    }

    @MainActor
    private func dismissSearchKeyboard() {
        searchFocused = false
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(80))
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        }
    }

    private func exportWorkspace() {
        let impact = UIImpactFeedbackGenerator(style: .medium)
        impact.impactOccurred()
        withAnimation { isExporting = true }
        
        let root = runtime.workspace.rootURL
        let workspaceName = runtime.workspace.workspaceName
        
        DispatchQueue.global(qos: .userInitiated).async {
            let coordinator = NSFileCoordinator()
            var error: NSError?
            
            coordinator.coordinate(readingItemAt: root, options: .forUploading, error: &error) { zipURL in
                let tempDir = FileManager.default.temporaryDirectory
                let destinationURL = tempDir.appendingPathComponent("\(workspaceName).zip")
                
                do {
                    try? FileManager.default.removeItem(at: destinationURL)
                    try FileManager.default.copyItem(at: zipURL, to: destinationURL)
                    DispatchQueue.main.async {
                        withAnimation { self.isExporting = false }
                        self.shareFile(destinationURL)
                    }
                } catch {
                    DispatchQueue.main.async {
                        withAnimation { self.isExporting = false }
                        self.fileActionError = "Could not export \(workspaceName): \(error.localizedDescription)"
                    }
                }
            }
            if error != nil {
                DispatchQueue.main.async {
                    withAnimation { self.isExporting = false }
                    self.fileActionError = "Could not export \(workspaceName): \(error?.localizedDescription ?? "Unknown coordinator error")"
                }
            }
        }
    }

    private func shareFile(_ url: URL) {
        let vc = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let rootVC = windowScene.windows.first?.rootViewController {
            vc.popoverPresentationController?.sourceView = rootVC.view
            rootVC.present(vc, animated: true)
        }
    }

    private func seedFileStressIfNeeded() {
        #if DEBUG
        seedFileActionsFixtureIfNeeded()

        guard ProcessInfo.processInfo.arguments.contains("--stress-files"), !didSeedFileStress else {
            return
        }
        didSeedFileStress = true

        if (try? runtime.workspace.read(".novaforge-file-stress")) == "v1",
           (try? runtime.workspace.read("Sources/Generated/Module12.swift"))?.contains("Fixture symbol 12") == true {
            return
        }

        try? runtime.workspace.makeDirectory("Sources/Generated")
        try? runtime.workspace.makeDirectory("Logs")
        for index in 1...36 {
            let source = """
            // NovaForge file stress fixture \(index)
            struct GeneratedModule\(index) {
                let fixture = "Fixture symbol \(index)"
                let path = "Sources/Generated/Module\(index).swift"
            }
            """
            try? runtime.workspace.write("Sources/Generated/Module\(index).swift", contents: source)
        }
        let logLines = (1...80)
            .map { "Fixture log line \($0): workspace search should stay quick and readable." }
            .joined(separator: "\n")
        try? runtime.workspace.write("Logs/build-summary.log", contents: logLines)
        try? runtime.workspace.write(".novaforge-file-stress", contents: "v1")
        runtime.noteWorkspaceChanged()
        #endif
    }

    private func seedFileActionsFixtureIfNeeded() {
        #if DEBUG
        guard ProcessInfo.processInfo.arguments.contains("--files-actions-test"), !didSeedFileStress else {
            return
        }
        didSeedFileStress = true
        try? runtime.workspace.makeDirectory("Actions")
        try? runtime.workspace.write("Actions/notes.md", contents: "# Actions fixture\n\nDuplicate/delete proof.\n")
        for path in ["Actions/notes_copy.md", "Actions/notes_copy 2.md", "Actions/notes_copy 3.md"] {
            try? runtime.workspace.delete(path)
        }
        currentPath = "Actions"
        runtime.noteWorkspaceChanged()
        #endif
    }

}

private struct FileMetricPill: View {
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
        VStack(spacing: 14) {
            AgentCenteredStateView(
                title: "Workspace folder is empty",
                detail: "Create a file here or ask NovaForge to generate one from Chat.",
                symbol: "folder.badge.plus",
                tint: AgentPalette.cyan
            )

            HStack(spacing: 10) {
                Button {
                    create()
                } label: {
                    Label("New File", systemImage: "doc.badge.plus")
                        .font(.system(size: 11, weight: .black, design: AgentPalette.interfaceFontDesign))
                        .frame(maxWidth: .infinity, minHeight: AgentDesign.minimumTouchTarget)
                        .agentControlSurface(radius: 12, tint: AgentPalette.cyan.opacity(0.16), selected: true)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("filesEmptyCreateFile")

                Button {
                    openChat()
                } label: {
                    Label("Ask Chat", systemImage: "sparkles")
                        .font(.system(size: 11, weight: .black, design: AgentPalette.interfaceFontDesign))
                        .frame(maxWidth: .infinity, minHeight: AgentDesign.minimumTouchTarget)
                        .agentControlSurface(radius: 12, tint: AgentPalette.lilac.opacity(0.16), selected: true)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("filesEmptyOpenChat")
            }
        }
        .padding(16)
        .agentSurface(radius: 22, tint: AgentPalette.cyan.opacity(0.08))
        .padding(.horizontal)
        .padding(.vertical, 20)
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

private struct FileSearchPrompt: View {
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

private struct FileSearchResultRow: View {
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
    let workspace: SandboxWorkspace
    let currentPath: String
    let onCreated: (String, Bool) -> Void
    
    @Environment(\.dismiss) private var dismiss
    @State private var fileName = ""
    @State private var isDirectory = false
    @State private var errorMessage: String? = nil
    @FocusState private var nameFocused: Bool

    private var trimmedName: String {
        fileName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var createDisabled: Bool {
        trimmedName.isEmpty
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
                }
                
                TextField(isDirectory ? "Folder name..." : "File name...", text: $fileName)
                    .textFieldStyle(.plain)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.none)
                    .submitLabel(.done)
                    .focused($nameFocused)
                    .padding(12)
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
                    .frame(maxWidth: .infinity)
                    .accessibilityIdentifier("createFileCancelButton")
                    
                    Button("Create") {
                        create()
                    }
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
    }
    
    private func create() {
        let name = trimmedName
        guard !name.isEmpty else { return }
        
        let targetRelativePath = currentPath.isEmpty ? name : "\(currentPath)/\(name)"
        
        do {
            if isDirectory {
                try workspace.createNewDirectory(targetRelativePath)
            } else {
                try workspace.createNewFile(targetRelativePath, contents: "")
            }
            let successImpact = UINotificationFeedbackGenerator()
            successImpact.notificationOccurred(.success)
            onCreated(targetRelativePath, isDirectory)
            dismiss()
        } catch {
            let errorImpact = UINotificationFeedbackGenerator()
            errorImpact.notificationOccurred(.error)
            errorMessage = error.localizedDescription
        }
    }
}

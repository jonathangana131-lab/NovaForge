//
//  FilesView+Search.swift
//  NovaForge
//
//  Search: sheet, query execution, results.
//

import AgentPolicy
import AgentTools
import SwiftData
import SwiftUI
import UIKit

/// Coalesces repeated SwiftUI lifecycle requests for the same debug fixture.
/// The task is deliberately retained independently of any one view lifetime so
/// a cancelled/recreated Files surface cannot dispatch a second seed midway
/// through the first policy-backed seed.
@MainActor
private final class FilesDebugFixtureSeedCoordinator {
    static let shared = FilesDebugFixtureSeedCoordinator()

    private var tasks: [String: Task<Void, Error>] = [:]

    func run(
        key: String,
        operation: @escaping @MainActor () async throws -> Void
    ) async throws {
        if let existingTask = tasks[key] {
            try await existingTask.value
            return
        }

        let task = Task { @MainActor in
            try await operation()
        }
        tasks[key] = task

        do {
            try await task.value
            tasks[key] = nil
        } catch {
            tasks[key] = nil
            throw error
        }
    }
}

extension FilesView {
    var searchSheet: some View {
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

    var searchSummaryText: String {
        let countText = searchStats.capped && searchResults.count >= searchResultLimit
            ? "\(searchResultLimit)+"
            : "\(searchResults.count)"
        return "\(countText) match\(searchResults.count == 1 ? "" : "es") for \"\(lastSearchQuery)\""
    }

    var searchDetailText: String {
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
    
    func runSearch() {
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

    func cancelSearch() {
        activeSearchID = nil
        searchTask?.cancel()
        searchTask = nil
        isSearching = false
    }

    func openResult(_ result: SearchResultItem) {
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
    func dismissSearchKeyboard() {
        searchFocused = false
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(80))
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        }
    }

    func exportWorkspace() {
        let impact = UIImpactFeedbackGenerator(style: .medium)
        impact.impactOccurred()
        withAnimation(reduceMotion ? nil : .default) { isExporting = true }
        
        let root = runtime.workspace.rootURL
        let workspaceName = runtime.workspace.workspaceName
        
        DispatchQueue.global(qos: .userInitiated).async {
            let coordinator = NSFileCoordinator()
            var error: NSError?
            
            coordinator.coordinate(readingItemAt: root, options: .forUploading, error: &error) { zipURL in
                let tempDir = FileManager.default.temporaryDirectory
                let destinationURL = tempDir.appendingPathComponent("\(workspaceName).zip")
                
                do {
                    // Mutation-boundary exemption: `zipURL` is a coordinated,
                    // read-only snapshot and `destinationURL` is an external
                    // temporary export. Neither operation mutates the sandbox
                    // workspace root, so no workspace journal permit applies.
                    try? FileManager.default.removeItem(at: destinationURL)
                    try FileManager.default.copyItem(at: zipURL, to: destinationURL)
                    DispatchQueue.main.async {
                        withAnimation(self.reduceMotion ? nil : .default) { self.isExporting = false }
                        self.shareFile(destinationURL)
                    }
                } catch {
                    DispatchQueue.main.async {
                        withAnimation(self.reduceMotion ? nil : .default) { self.isExporting = false }
                        self.fileActionError = "Could not export \(workspaceName): \(error.localizedDescription)"
                    }
                }
            }
            if error != nil {
                DispatchQueue.main.async {
                    withAnimation(self.reduceMotion ? nil : .default) { self.isExporting = false }
                    self.fileActionError = "Could not export \(workspaceName): \(error?.localizedDescription ?? "Unknown coordinator error")"
                }
            }
        }
    }

    func shareFile(_ url: URL) {
        let vc = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let rootVC = windowScene.windows.first?.rootViewController {
            vc.popoverPresentationController?.sourceView = rootVC.view
            rootVC.present(vc, animated: true)
        }
    }

    @MainActor
    func seedFileStressIfNeeded() {
        #if DEBUG
        guard !didSeedFileStress, !isSeedingFileStress else {
            return
        }

        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--files-actions-test") {
            seedFileActionsFixtureIfNeeded()
            return
        }
        guard arguments.contains("--stress-files") else { return }
        isSeedingFileStress = true

        let fixtureKey = "\(runtime.workspace.rootURL.standardizedFileURL.path)|file-stress-v1"
        Task { @MainActor in
            defer { isSeedingFileStress = false }
            let approvalTask = Task { @MainActor in
                await approveExpectedSearchFixtureMutations(
                    searchFileStressOperations()
                )
            }
            defer { approvalTask.cancel() }
            do {
                try await FilesDebugFixtureSeedCoordinator.shared.run(key: fixtureKey) {
                    try await seedFileStressFixture()
                }
                // This is a success flag. The explicit in-flight flag and
                // shared coordinator prevent duplicate dispatch until every
                // durable mutation receipt has completed.
                didSeedFileStress = true
                runtime.noteWorkspaceChanged()
                reload()
                reloadWorkspaces()
                // The receipts above are the durable completion boundary.
                // Give the detached browser projection one render turn; its
                // task identity may be replaced by SwiftUI lifecycle reloads,
                // so observing the shared task slot is not a completion API.
                try? await Task.sleep(for: .milliseconds(500))
                isFileStressFixtureReady = true
            } catch {
                if let message = filesMutationFailureMessage(
                    action: "Could not prepare the file stress fixture",
                    error: error
                ) {
                    fileActionError = message
                }
            }
        }
        #endif
    }

    #if DEBUG
    @MainActor
    private func seedFileStressFixture() async throws {
        if (try? runtime.workspace.read(".novaforge-file-stress")) == "v1",
           (try? runtime.workspace.read("Sources/Generated/Module12.swift"))?.contains("Fixture symbol 12") == true {
            return
        }

        for operation in searchFileStressOperations() {
            try Task.checkCancellation()
            _ = try await performSearchFixtureMutation(operation)
        }
    }
    #endif

    @MainActor
    func seedFileActionsFixtureIfNeeded() {
        #if DEBUG
        guard ProcessInfo.processInfo.arguments.contains("--files-actions-test"),
              !didSeedFileStress,
              !isSeedingFileStress else {
            return
        }
        isSeedingFileStress = true

        let fixtureKey = "\(runtime.workspace.rootURL.standardizedFileURL.path)|file-actions-v1"
        Task { @MainActor in
            defer { isSeedingFileStress = false }
            let approvalTask = Task { @MainActor in
                await approveExpectedSearchFixtureMutations(
                    searchFileActionsOperations()
                )
            }
            defer { approvalTask.cancel() }
            do {
                try await FilesDebugFixtureSeedCoordinator.shared.run(key: fixtureKey) {
                    try await seedFileActionsFixture()
                }
                // UI state changes only after every mutation receipt, including
                // cleanup deletes, has reached durable completion.
                didSeedFileStress = true
                currentPath = "Actions"
                runtime.noteWorkspaceChanged()
                reload()
                reloadWorkspaces()
                try? await Task.sleep(for: .milliseconds(500))
                isFileStressFixtureReady = true
            } catch {
                if let message = filesMutationFailureMessage(
                    action: "Could not prepare the file actions fixture",
                    error: error
                ) {
                    fileActionError = message
                }
            }
        }
        #endif
    }

    #if DEBUG
    @MainActor
    private func seedFileActionsFixture() async throws {
        _ = try await performSearchFixtureMutation(
            .makeDirectory(PathArguments(path: "Actions"))
        )
        _ = try await performSearchFixtureMutation(
            .writeFile(WriteFileArguments(
                path: "Actions/notes.md",
                contents: "# Actions fixture\n\nDuplicate/delete proof.\n"
            ))
        )

        for path in ["Actions/notes_copy.md", "Actions/notes_copy 2.md", "Actions/notes_copy 3.md"] {
            try Task.checkCancellation()
            let targetURL = try runtime.workspace.resolve(path)
            guard FileManager.default.fileExists(atPath: targetURL.path)
            else { continue }
            _ = try await performSearchFixtureMutation(
                .deletePath(PathArguments(path: path))
            )
        }
    }
    #endif

    @MainActor
    private func performSearchFixtureMutation(
        _ operation: FilesCanonicalMutationOperation
    ) async throws -> AgentPolicyMutationReceipt {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains("--stress-files") ||
                arguments.contains("--files-actions-test") else {
            throw CocoaError(.userCancelled)
        }

        // Fixtures still cross the exact Files policy boundary and receive a
        // durable receipt. The narrowly launch-flagged debug task acts as the
        // test operator, approving only the matching Files preview; production
        // builds contain neither this path nor ambient authorization.
        let operationID = UUID()
        return try await performFilesMutation(
            operationID: operationID,
            operation: operation
        )
        #else
        throw CocoaError(.userCancelled)
        #endif
    }

    #if DEBUG
    @MainActor
    private func approveExpectedSearchFixtureMutations(
        _ expectedOperations: [FilesCanonicalMutationOperation]
    ) async {
        let promptCenter = AgentPolicyMutationRuntime.shared.approvalPromptCenter
        while !Task.isCancelled {
            if let item = promptCenter.pendingItem,
               item.origin == .files,
               expectedOperations.contains(where: {
                   searchFixturePreview(item.operation, matches: $0)
               })
            {
                _ = promptCenter.approve(requestID: item.requestID)
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private func searchFileStressOperations() -> [FilesCanonicalMutationOperation] {
        var operations: [FilesCanonicalMutationOperation] = [
            .makeDirectory(PathArguments(path: "Sources/Generated")),
            .makeDirectory(PathArguments(path: "Logs")),
        ]
        // Twelve generated modules exercise folder navigation, list/grid
        // rendering, and multi-file search while keeping this debug fixture
        // comfortably inside the UI test's 90-second durable-seed budget.
        operations.append(contentsOf: (1...12).map { fixtureIndex in
            let path = "Sources/Generated/Module\(fixtureIndex).swift"
            let source = """
            // NovaForge file stress fixture \(fixtureIndex)
            struct GeneratedModule\(fixtureIndex) {
                let fixture = "Fixture symbol \(fixtureIndex)"
                let path = "\(path)"
            }
            """
            return .writeFile(WriteFileArguments(path: path, contents: source))
        })
        let logLines = (1...80)
            .map { "Fixture log line \($0): workspace search should stay quick and readable." }
            .joined(separator: "\n")
        operations.append(.writeFile(WriteFileArguments(
            path: "Logs/build-summary.log",
            contents: logLines
        )))
        // Commit the marker last. An interrupted partial fixture therefore
        // remains eligible for a safe, idempotent repair.
        operations.append(.writeFile(WriteFileArguments(
            path: ".novaforge-file-stress",
            contents: "v1"
        )))
        return operations
    }

    private func searchFileActionsOperations() -> [FilesCanonicalMutationOperation] {
        var operations: [FilesCanonicalMutationOperation] = [
            .makeDirectory(PathArguments(path: "Actions")),
            .writeFile(WriteFileArguments(
                path: "Actions/notes.md",
                contents: "# Actions fixture\n\nDuplicate/delete proof.\n"
            )),
        ]
        operations.append(contentsOf: [
            "Actions/notes_copy.md",
            "Actions/notes_copy 2.md",
            "Actions/notes_copy 3.md",
        ].map { .deletePath(PathArguments(path: $0)) })
        return operations
    }

    private func searchFixturePreview(
        _ preview: AgentApprovalPromptCenter.PendingItem.OperationPreview,
        matches operation: FilesCanonicalMutationOperation
    ) -> Bool {
        switch (preview, operation) {
        case let (.writeFile(path, byteCount), .writeFile(arguments)):
            path == arguments.path && byteCount == arguments.contents.utf8.count
        case let (.deletePath(path), .deletePath(arguments)):
            path == arguments.path
        case let (.makeDirectory(path), .makeDirectory(arguments)):
            path == arguments.path
        case let (.movePath(source, destination), .movePath(arguments)):
            source == arguments.from && destination == arguments.to
        case let (.copyPath(source, destination), .copyPath(arguments)):
            source == arguments.from && destination == arguments.to
        default:
            false
        }
    }
    #endif
}

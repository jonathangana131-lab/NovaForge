//
//  FilesView+Search.swift
//  NovaForge
//
//  Search: sheet, query execution, results.
//

import SwiftData
import SwiftUI
import UIKit

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

    func shareFile(_ url: URL) {
        let vc = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let rootVC = windowScene.windows.first?.rootViewController {
            vc.popoverPresentationController?.sourceView = rootVC.view
            rootVC.present(vc, animated: true)
        }
    }

    func seedFileStressIfNeeded() {
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

    func seedFileActionsFixtureIfNeeded() {
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

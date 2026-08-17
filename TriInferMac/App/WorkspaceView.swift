import SwiftUI
import WebKit

struct WorkspaceView: View {
    @Bindable var model: AppModel
    @State private var entries: [WorkspaceManager.Entry] = []
    @State private var query = ""
    @State private var showPreview = false
    @State private var isRefreshing = false
    @State private var validationMessage: String?

    private var visibleEntries: [WorkspaceManager.Entry] {
        let clean = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !clean.isEmpty else { return entries }
        return entries.filter {
            $0.relativePath.lowercased().contains(clean) || $0.name.lowercased().contains(clean)
        }
    }

    private var fileCount: Int { entries.filter { !$0.isDirectory }.count }
    private var directoryCount: Int { entries.filter(\.isDirectory).count }
    private var totalBytes: Int64 { entries.filter { !$0.isDirectory }.reduce(0) { $0 + $1.size } }

    var body: some View {
        List {
            Section {
                VStack(spacing: 12) {
                    HStack(spacing: 12) {
                        Image(systemName: "folder.badge.gearshape")
                            .font(.title2)
                            .foregroundStyle(.blue)
                            .frame(width: 46, height: 46)
                            .glassEffect(.regular, in: .rect(cornerRadius: 15))
                        VStack(alignment: .leading, spacing: 3) {
                            Text(model.workspaceTitle)
                                .font(.headline)
                            Text("\(fileCount) files • \(directoryCount) folders • \(ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if isRefreshing { ProgressView().controlSize(.small) }
                    }

                    HStack(spacing: 10) {
                        Button { showPreview = true } label: {
                            Label("Preview", systemImage: "play.rectangle.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)

                        Button { Task { await validateBrowserProject() } } label: {
                            Label("Validate", systemImage: "checkmark.seal")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .padding(.vertical, 4)
            }

            Section("Project") {
                if visibleEntries.isEmpty {
                    ContentUnavailableView.search(text: query)
                } else {
                    ForEach(visibleEntries) { entry in
                        if entry.isDirectory {
                            HStack(spacing: 10) {
                                Image(systemName: "folder.fill")
                                    .foregroundStyle(.secondary)
                                    .frame(width: 20)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(entry.name).font(.subheadline.weight(.medium))
                                    Text(parent(entry.relativePath)).font(.caption2).foregroundStyle(.tertiary)
                                }
                                Spacer()
                            }
                        } else {
                            NavigationLink(value: entry.relativePath) {
                                HStack(spacing: 10) {
                                    Image(systemName: symbol(for: entry.relativePath))
                                        .foregroundStyle(symbolColor(for: entry.relativePath))
                                        .frame(width: 20)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(entry.name).lineLimit(1)
                                        Text(parent(entry.relativePath)).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                                    }
                                    Spacer()
                                    Text(ByteCountFormatter.string(fromByteCount: entry.size, countStyle: .file))
                                        .font(.caption2.monospacedDigit())
                                        .foregroundStyle(.tertiary)
                                }
                            }
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Workspace")
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .automatic), prompt: "Find files or folders")
        .navigationDestination(for: String.self) { path in
            FileDetailView(workspace: model.workspace, path: path)
        }
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    Task {
                        _ = try? await model.workspace.undo()
                        await reload()
                    }
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                }
                .accessibilityLabel("Undo last workspace change")

                Menu {
                    Button("Refresh", systemImage: "arrow.clockwise") { Task { await reload() } }
                    Button("Validate Browser Project", systemImage: "checkmark.seal") { Task { await validateBrowserProject() } }
                    Divider()
                    Button("Reset Browser Template", systemImage: "sparkles") {
                        Task {
                            try? await model.workspace.createBrowserTemplate(overwrite: true)
                            await reload()
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .sheet(isPresented: $showPreview) { ArtifactPreviewSheet(workspace: model.workspace) }
        .alert(
            "Browser Project Check",
            isPresented: Binding(
                get: { validationMessage != nil },
                set: { if !$0 { validationMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) { validationMessage = nil }
        } message: {
            Text(validationMessage ?? "")
        }
        .task { await reload() }
        .refreshable { await reload() }
    }

    private func reload() async {
        isRefreshing = true
        entries = (try? await model.workspace.entries()) ?? []
        isRefreshing = false
    }

    private func validateBrowserProject() async {
        do { validationMessage = try await model.workspace.validateBrowserProject() }
        catch { validationMessage = "Could not validate the workspace: \(error.localizedDescription)" }
    }

    private func parent(_ path: String) -> String {
        let parent = URL(fileURLWithPath: path).deletingLastPathComponent().path
        return parent == "." || parent == "/" ? "Project root" : parent
    }

    private func symbol(for path: String) -> String {
        switch URL(fileURLWithPath: path).pathExtension.lowercased() {
        case "html": "safari"
        case "css": "paintbrush"
        case "js", "mjs", "ts", "tsx", "jsx": "curlybraces"
        case "json": "text.page"
        case "md": "doc.richtext"
        case "png", "jpg", "jpeg", "webp", "gif": "photo"
        case "wav", "mp3", "m4a": "waveform"
        default: "doc.text"
        }
    }

    private func symbolColor(for path: String) -> Color {
        switch URL(fileURLWithPath: path).pathExtension.lowercased() {
        case "html": .orange
        case "css": .blue
        case "js", "mjs", "ts", "tsx", "jsx": .yellow
        case "json": .green
        default: .secondary
        }
    }
}

private struct FileDetailView: View {
    let workspace: WorkspaceManager
    let path: String
    @State private var text = ""
    @State private var error: String?
    @State private var search = ""

    private var lines: [Substring] { text.split(separator: "\n", omittingEmptySubsequences: false) }

    var body: some View {
        Group {
            if let error {
                ContentUnavailableView("Couldn’t Open File", systemImage: "exclamationmark.triangle", description: Text(error))
            } else if text.isEmpty {
                ProgressView("Loading source…")
            } else {
                ScrollView([.horizontal, .vertical]) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                            HStack(alignment: .firstTextBaseline, spacing: 12) {
                                Text("\(index + 1)")
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(.tertiary)
                                    .frame(width: 36, alignment: .trailing)
                                    .textSelection(.disabled)
                                Text(line.isEmpty ? " " : String(line))
                                    .font(.system(.footnote, design: .monospaced))
                                    .foregroundStyle(highlight(line: String(line)))
                                    .textSelection(.enabled)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 1)
                        }
                    }
                    .padding(.vertical, 12)
                }
                .background(Color(uiColor: .secondarySystemBackground).opacity(0.35))
            }
        }
        .navigationTitle(URL(fileURLWithPath: path).lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                ShareLink(item: text, subject: Text(URL(fileURLWithPath: path).lastPathComponent)) {
                    Image(systemName: "square.and.arrow.up")
                }
                .disabled(text.isEmpty)
            }
        }
        .task {
            do { text = try await workspace.read(path) }
            catch { self.error = error.localizedDescription }
        }
    }

    private func highlight(line: String) -> Color {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("//") || trimmed.hasPrefix("/*") || trimmed.hasPrefix("*") || trimmed.hasPrefix("<!--") { return .secondary }
        if trimmed.hasPrefix("import ") || trimmed.hasPrefix("export ") || trimmed.hasPrefix("func ") || trimmed.hasPrefix("function ") { return .primary }
        return .primary
    }
}

struct ArtifactPreviewSheet: View {
    let workspace: WorkspaceManager
    @Environment(\.dismiss) private var dismiss
    @State private var root: URL?
    @State private var reloadID = UUID()
    @State private var loadError: String?

    var body: some View {
        NavigationStack {
            Group {
                if let root {
                    BrowserArtifactView(root: root, reloadID: reloadID, loadError: $loadError)
                        .ignoresSafeArea(edges: .bottom)
                } else {
                    ProgressView("Preparing preview…")
                }
            }
            .safeAreaInset(edge: .bottom) {
                if let loadError {
                    Label(loadError, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.ultraThinMaterial)
                }
            }
            .navigationTitle("Artifact Preview")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { reloadID = UUID(); loadError = nil } label: { Image(systemName: "arrow.clockwise") }
                        .disabled(root == nil)
                }
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
            }
        }
        .task { root = await workspace.rootURL() }
    }
}

private struct BrowserArtifactView: UIViewRepresentable {
    let root: URL
    let reloadID: UUID
    @Binding var loadError: String?

    func makeCoordinator() -> Coordinator { Coordinator(loadError: $loadError) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.preferences.isElementFullscreenEnabled = true
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        let web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = context.coordinator
        web.isInspectable = true
        web.scrollView.contentInsetAdjustmentBehavior = .never
        load(web)
        return web
    }

    func updateUIView(_ web: WKWebView, context: Context) {
        guard context.coordinator.reloadID != reloadID else { return }
        context.coordinator.reloadID = reloadID
        load(web)
    }

    private func load(_ web: WKWebView) {
        let index = root.appendingPathComponent("index.html")
        web.loadFileURL(index, allowingReadAccessTo: root)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var reloadID: UUID?
        @Binding var loadError: String?

        init(loadError: Binding<String?>) { _loadError = loadError }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            loadError = nil
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            loadError = error.localizedDescription
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            loadError = error.localizedDescription
        }
    }
}

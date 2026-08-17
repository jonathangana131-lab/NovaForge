import SwiftUI
import WebKit

struct WorkspaceView: View {
    @Bindable var model: AppModel
    @State private var entries: [WorkspaceManager.Entry] = []
    @State private var showPreview = false
    @State private var isRefreshing = false

    var body: some View {
        List {
            Section {
                Button { showPreview = true } label: {
                    HStack(spacing: 12) {
                        ZStack { RoundedRectangle(cornerRadius: 12).fill(.thinMaterial); Image(systemName: "play.rectangle.fill").font(.title3) }.frame(width: 42, height: 42)
                        VStack(alignment: .leading, spacing: 2) { Text("Run Browser Artifact").font(.headline); Text("index.html • full workspace read access").font(.caption).foregroundStyle(.secondary) }
                        Spacer(); Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                    }
                }.buttonStyle(.plain)
            }
            Section("Project") {
                ForEach(entries) { entry in
                    if entry.isDirectory {
                        HStack { Image(systemName: "folder.fill").foregroundStyle(.secondary); Text(entry.relativePath).font(.subheadline.weight(.medium)); Spacer() }
                    } else {
                        NavigationLink(value: entry.relativePath) {
                            HStack(spacing: 10) {
                                Image(systemName: symbol(for: entry.relativePath)).foregroundStyle(.secondary).frame(width: 20)
                                VStack(alignment: .leading, spacing: 2) { Text(entry.name); Text(parent(entry.relativePath)).font(.caption2).foregroundStyle(.tertiary) }
                                Spacer()
                                Text(ByteCountFormatter.string(fromByteCount: entry.size, countStyle: .file)).font(.caption2).foregroundStyle(.tertiary)
                            }
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(model.workspaceTitle)
        .navigationDestination(for: String.self) { path in FileDetailView(workspace: model.workspace, path: path) }
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button { Task { _ = try? await model.workspace.undo(); await reload() } } label: { Image(systemName: "arrow.uturn.backward") }
                Menu {
                    Button("Refresh", systemImage: "arrow.clockwise") { Task { await reload() } }
                    Button("Reset Browser Template", systemImage: "sparkles") { Task { try? await model.workspace.createBrowserTemplate(overwrite: true); await reload() } }
                } label: { Image(systemName: "ellipsis.circle") }
            }
        }
        .sheet(isPresented: $showPreview) { ArtifactPreviewSheet(workspace: model.workspace) }
        .task { await reload() }
        .refreshable { await reload() }
    }

    private func reload() async {
        isRefreshing = true
        entries = (try? await model.workspace.entries()) ?? []
        isRefreshing = false
    }

    private func parent(_ path: String) -> String {
        let parent = URL(fileURLWithPath: path).deletingLastPathComponent().path
        return parent == "." || parent == "/" ? "Project root" : parent
    }

    private func symbol(for path: String) -> String {
        switch URL(fileURLWithPath: path).pathExtension.lowercased() {
        case "html": "safari"
        case "css": "paintbrush"
        case "js", "ts": "curlybraces"
        case "json": "text.page"
        case "md": "doc.richtext"
        default: "doc.text"
        }
    }
}

private struct FileDetailView: View {
    let workspace: WorkspaceManager
    let path: String
    @State private var text = ""
    @State private var error: String?
    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            Text(text.isEmpty ? " " : text)
                .font(.system(.footnote, design: .monospaced)).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .topLeading).padding(16)
        }
        .background(Color(uiColor: .secondarySystemBackground).opacity(0.35))
        .navigationTitle(URL(fileURLWithPath: path).lastPathComponent).navigationBarTitleDisplayMode(.inline)
        .overlay { if let error { ContentUnavailableView("Couldn’t Open File", systemImage: "exclamationmark.triangle", description: Text(error)) } }
        .task {
            do { text = try await workspace.read(path) }
            catch { self.error = error.localizedDescription }
        }
    }
}

struct ArtifactPreviewSheet: View {
    let workspace: WorkspaceManager
    @Environment(\.dismiss) private var dismiss
    @State private var root: URL?
    var body: some View {
        NavigationStack {
            Group {
                if let root { BrowserArtifactView(root: root) }
                else { ProgressView("Preparing preview…") }
            }
            .navigationTitle("Artifact Preview").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
        }
        .task { root = await workspace.rootURL() }
    }
}

private struct BrowserArtifactView: UIViewRepresentable {
    let root: URL
    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.preferences.isElementFullscreenEnabled = true
        let web = WKWebView(frame: .zero, configuration: config)
        web.isInspectable = true
        web.scrollView.contentInsetAdjustmentBehavior = .never
        let index = root.appendingPathComponent("index.html")
        web.loadFileURL(index, allowingReadAccessTo: root)
        return web
    }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

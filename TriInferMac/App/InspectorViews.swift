import SwiftUI

struct ActivityView: View {
    @Bindable var model: AppModel
    var body: some View {
        List {
            if model.events.isEmpty { EmptyState(symbol: "waveform.path.ecg", title: "No agent activity yet", message: "Tool calls, checkpoints, compaction, warnings, and completed steps appear here.") }
            ForEach(model.events.reversed()) { event in
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: symbol(event.kind)).foregroundStyle(tint(event.kind)).frame(width: 30, height: 30).background(.thinMaterial, in: Circle())
                    VStack(alignment: .leading, spacing: 4) { Text(event.title).font(.subheadline.weight(.semibold)); Text(event.detail).font(.caption).foregroundStyle(.secondary); Text(event.timestamp, style: .time).font(.caption2).foregroundStyle(.tertiary) }
                }.padding(.vertical, 4)
            }
        }.navigationTitle("Activity")
    }
    private func symbol(_ kind: AppModel.AgentEvent.Kind) -> String { switch kind { case .thinking: "brain.head.profile"; case .tool: "wrench.and.screwdriver"; case .checkpoint: "bookmark"; case .memory: "externaldrive.badge.checkmark"; case .warning: "exclamationmark.triangle"; case .success: "checkmark.circle" } }
    private func tint(_ kind: AppModel.AgentEvent.Kind) -> Color { switch kind { case .warning: .orange; case .success: .green; case .memory: .purple; default: .secondary } }
}

struct TodoView: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                ForEach($model.todos) { $todo in
                    HStack(spacing: 12) {
                        Button { cycle(&todo) } label: { Image(systemName: todo.state == .done ? "checkmark.circle.fill" : todo.state == .active ? "circle.inset.filled" : "circle").foregroundStyle(todo.state == .done ? .green : .primary) }.buttonStyle(.plain)
                        Text(todo.title).strikethrough(todo.state == .done).foregroundStyle(todo.state == .done ? .secondary : .primary)
                    }
                }
            }.navigationTitle("Tasks").toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
        }
    }
    private func cycle(_ todo: inout AppModel.Todo) { todo.state = todo.state == .pending ? .active : todo.state == .active ? .done : .pending }
}

struct ContextInspectorView: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var snapshot: ContextEngine.Snapshot?
    var body: some View {
        NavigationStack {
            List {
                Section("Hot context") {
                    LabeledContent("Estimated chat tokens", value: "\(snapshot?.estimatedTokens ?? 0)")
                    LabeledContent("Stable cached prefix", value: "~\(snapshot?.cachedPrefixEstimate ?? 0) tok")
                    LabeledContent("Compressed turns", value: "\(snapshot?.compressedTurns ?? 0)")
                }
                Section("Compacted history") { Text(snapshot?.summary.isEmpty == false ? snapshot!.summary : "Nothing has needed compaction yet.").font(.callout).foregroundStyle(.secondary) }
                Section("Durable project facts") {
                    if snapshot?.facts.isEmpty != false { Text("No pinned facts yet.").foregroundStyle(.secondary) }
                    ForEach(snapshot?.facts ?? []) { fact in VStack(alignment: .leading, spacing: 3) { Text(fact.text); Text(fact.source).font(.caption).foregroundStyle(.secondary) } }
                }
                Section { Text("TriInfer keeps authoritative project state in the workspace and structured stores, retrieves only relevant slices, and keeps the prompt prefix stable for KV reuse. Old tool output is elided instead of growing forever.").font(.footnote).foregroundStyle(.secondary) }
            }
            .navigationTitle("Context")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
            .task { snapshot = await model.context.snapshot(messages: model.messages) }
        }
    }
}

struct PerformanceView: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    private var preview: Bool { model.runtimeMetrics.backend.lowercased().contains("simulator preview") }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    if preview { Label("Simulator preview data — not an iPhone 12 benchmark", systemImage: "info.circle").font(.caption.weight(.semibold)).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading) }
                    HStack(spacing: 10) { big("TOKENS / SEC", String(format: "%.2f", model.runtimeMetrics.tokensPerSecond)); big("TTFT", model.runtimeMetrics.timeToFirstTokenMS > 0 ? "\(Int(model.runtimeMetrics.timeToFirstTokenMS)) ms" : "—") }
                    VStack(spacing: 0) {
                        row("Backend", model.runtimeMetrics.backend); Divider(); row("Prompt tokens", "\(model.runtimeMetrics.promptTokens)"); Divider(); row("Cached prefix", "\(model.runtimeMetrics.cachedPrefixTokens)"); Divider(); row("Output tokens", "\(model.runtimeMetrics.outputTokens)"); Divider(); row("Thermal state", model.runtimeMetrics.thermal); Divider(); row("Context", "\(model.runtimeMetrics.contextTokens) / \(model.runtimeMetrics.contextBudget)")
                    }.padding(16).background(.thinMaterial, in: RoundedRectangle(cornerRadius: 22))
                    Text("For 27B, the app uses a deliberately small hot context and conservative Metal residency so iOS and the UI keep headroom. Real device measurements decide whether more layers can be pinned without jetsam or thermal regression.").font(.footnote).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                }.padding(16)
            }.navigationTitle("Performance").toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
        }
    }
    private func big(_ title: String, _ value: String) -> some View { VStack(alignment: .leading, spacing: 6) { Text(title).font(.caption2.weight(.bold)).foregroundStyle(.secondary); Text(value).font(.system(size: 28, weight: .semibold, design: .rounded)).minimumScaleFactor(.7) }.frame(maxWidth: .infinity, alignment: .leading).padding(16).background(.thinMaterial, in: RoundedRectangle(cornerRadius: 22)) }
    private func row(_ title: String, _ value: String) -> some View { HStack { Text(title).foregroundStyle(.secondary); Spacer(); Text(value).font(.subheadline.weight(.medium)).multilineTextAlignment(.trailing) }.padding(.vertical, 10) }
}

struct HistoryView: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                Section("Current run checkpoints") {
                    let checkpoints = model.events.filter { $0.kind == .checkpoint }.reversed()
                    if checkpoints.isEmpty { Text("Checkpoints are written as the agent works.").foregroundStyle(.secondary) }
                    ForEach(Array(checkpoints)) { event in VStack(alignment: .leading, spacing: 4) { Text(event.title).font(.subheadline.weight(.semibold)); Text(event.detail).font(.caption).foregroundStyle(.secondary); Text(event.timestamp, style: .relative).font(.caption2).foregroundStyle(.tertiary) } }
                }
            }.navigationTitle("History").toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
        }
    }
}

struct SettingsView: View {
    @Bindable var model: AppModel
    @AppStorage("TriInfer.thermalGuard") private var thermalGuard = true
    @AppStorage("TriInfer.autoCompact") private var autoCompact = true
    @AppStorage("TriInfer.performanceOverlay") private var performanceOverlay = true
    var body: some View {
        Form {
            Section("Inference") {
                LabeledContent("Loaded model", value: model.currentModelName)
                Toggle("Protect sustained speed from thermal throttling", isOn: $thermalGuard)
                Toggle("Show performance telemetry", isOn: $performanceOverlay)
            }
            Section("Agent") {
                Toggle("Automatic context compaction", isOn: $autoCompact)
                LabeledContent("Maximum guarded steps", value: "128")
                LabeledContent("Workspace policy", value: "Sandboxed")
                LabeledContent("Tool protocol", value: "Compact JSON")
            }
            Section("About") {
                LabeledContent("Runtime", value: "llama.cpp / Metal / CPU")
                LabeledContent("UI", value: "Native SwiftUI")
                LabeledContent("Version", value: "3.0")
                Text("All model inference and project files stay local unless you explicitly download a model or choose an external workspace.").font(.footnote).foregroundStyle(.secondary)
            }
        }.navigationTitle("Settings")
    }
}

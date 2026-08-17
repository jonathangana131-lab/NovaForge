import SwiftUI

struct ActivityView: View {
    @Bindable var model: AppModel

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                if model.events.isEmpty {
                    ContentUnavailableView(
                        "No agent activity yet",
                        systemImage: "waveform.path.ecg",
                        description: Text("Tool calls, checkpoints, memory compaction, warnings, and completed steps appear here.")
                    )
                    .padding(.top, 70)
                }

                ForEach(model.events.reversed()) { event in
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: symbol(event.kind))
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(tint(event.kind))
                            .frame(width: 34, height: 34)
                            .glassEffect(.regular, in: .circle)

                        VStack(alignment: .leading, spacing: 5) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(event.title).font(.subheadline.weight(.semibold))
                                Spacer()
                                Text(event.timestamp, style: .time)
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                            Text(event.detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                    .padding(14)
                    .glassEffect(.regular, in: .rect(cornerRadius: 20))
                }
            }
            .padding(16)
        }
        .navigationTitle("Activity")
        .background(Color(uiColor: .systemGroupedBackground))
    }

    private func symbol(_ kind: AppModel.AgentEvent.Kind) -> String {
        switch kind {
        case .thinking: "brain.head.profile"
        case .tool: "wrench.and.screwdriver"
        case .checkpoint: "bookmark.fill"
        case .memory: "externaldrive.badge.checkmark"
        case .warning: "exclamationmark.triangle.fill"
        case .success: "checkmark.circle.fill"
        }
    }

    private func tint(_ kind: AppModel.AgentEvent.Kind) -> Color {
        switch kind {
        case .warning: .orange
        case .success: .green
        case .memory: .purple
        case .checkpoint: .blue
        default: .secondary
        }
    }
}

struct TodoView: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach($model.todos) { $todo in
                        HStack(spacing: 12) {
                            Button { cycle(&todo) } label: {
                                Image(systemName: todo.state == .done ? "checkmark.circle.fill" : todo.state == .active ? "circle.inset.filled" : "circle")
                                    .font(.title3)
                                    .foregroundStyle(todo.state == .done ? .green : todo.state == .active ? .blue : .secondary)
                            }
                            .buttonStyle(.plain)
                            Text(todo.title)
                                .strikethrough(todo.state == .done)
                                .foregroundStyle(todo.state == .done ? .secondary : .primary)
                        }
                        .padding(.vertical, 3)
                    }
                } footer: {
                    Text("TODO state is stored outside the model prompt and survives context compaction.")
                }
            }
            .navigationTitle("Tasks")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
        }
    }

    private func cycle(_ todo: inout AppModel.Todo) {
        todo.state = todo.state == .pending ? .active : todo.state == .active ? .done : .pending
    }
}

struct ContextInspectorView: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var snapshot: ContextEngine.Snapshot?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    HStack(spacing: 10) {
                        metric("HOT CHAT", "\(snapshot?.estimatedTokens ?? 0)", "tokens")
                        metric("EXTERNAL", "\(snapshot?.experienceCount ?? 0)", "memories")
                    }
                    HStack(spacing: 10) {
                        metric("CACHED PREFIX", "~\(snapshot?.cachedPrefixEstimate ?? 0)", "tokens")
                        metric("COMPACTED", "\(snapshot?.compressedTurns ?? 0)", "turns")
                    }

                    sectionCard("Working summary", symbol: "text.compress") {
                        Text(snapshot?.summary.isEmpty == false ? snapshot!.summary : "Nothing has needed compaction yet.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }

                    sectionCard("Pinned facts", symbol: "pin.fill") {
                        if snapshot?.facts.isEmpty != false {
                            Text("No pinned facts yet.").foregroundStyle(.secondary)
                        } else {
                            VStack(alignment: .leading, spacing: 10) {
                                ForEach(snapshot?.facts ?? []) { fact in
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(fact.text).font(.callout)
                                        Text(fact.source).font(.caption2).foregroundStyle(.tertiary)
                                    }
                                }
                            }
                        }
                    }

                    sectionCard("Recent experience IDs", symbol: "externaldrive.fill.badge.checkmark") {
                        if snapshot?.recentExperiences.isEmpty != false {
                            Text("Exact old tool results will appear here after the agent starts working.")
                                .foregroundStyle(.secondary)
                        } else {
                            VStack(alignment: .leading, spacing: 10) {
                                ForEach(snapshot?.recentExperiences ?? []) { item in
                                    HStack(alignment: .top, spacing: 8) {
                                        Text(item.id)
                                            .font(.caption.monospaced().weight(.semibold))
                                            .foregroundStyle(.blue)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(item.title).font(.callout.weight(.medium))
                                            if !item.paths.isEmpty {
                                                Text(item.paths.joined(separator: ", "))
                                                    .font(.caption2)
                                                    .foregroundStyle(.tertiary)
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }

                    Text("TriInfer keeps full-fidelity old evidence outside the KV cache under stable memory IDs, retrieves only relevant project slices, and preserves a small hot prompt. This reduces RAM and next-message prefill growth without throwing away exact debugging evidence.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 4)
                }
                .padding(16)
            }
            .navigationTitle("Context & Memory")
            .background(Color(uiColor: .systemGroupedBackground))
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
            .task { snapshot = await model.context.snapshot(messages: model.messages) }
        }
    }

    private func metric(_ title: String, _ value: String, _ suffix: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption2.weight(.bold)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 25, weight: .semibold, design: .rounded))
            Text(suffix).font(.caption2).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(15)
        .glassEffect(.regular, in: .rect(cornerRadius: 20))
    }

    private func sectionCard<Content: View>(_ title: String, symbol: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: symbol).font(.headline)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .glassEffect(.regular, in: .rect(cornerRadius: 22))
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
                    if preview {
                        Label("Simulator showcase data — not an iPhone 12 benchmark", systemImage: "info.circle.fill")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    HStack(spacing: 10) {
                        big("TOKENS / SEC", String(format: "%.2f", model.runtimeMetrics.tokensPerSecond))
                        big("TTFT", model.runtimeMetrics.timeToFirstTokenMS > 0 ? "\(Int(model.runtimeMetrics.timeToFirstTokenMS)) ms" : "—")
                    }

                    VStack(spacing: 0) {
                        row("Backend", model.runtimeMetrics.backend)
                        Divider()
                        row("Prompt tokens", "\(model.runtimeMetrics.promptTokens)")
                        Divider()
                        row("Cached prefix", "\(model.runtimeMetrics.cachedPrefixTokens)")
                        Divider()
                        row("Output tokens", "\(model.runtimeMetrics.outputTokens)")
                        Divider()
                        row("Metal allocated", model.runtimeMetrics.memoryMB > 0 ? String(format: "%.0f MB", model.runtimeMetrics.memoryMB) : "—")
                        Divider()
                        row("Thermal", model.runtimeMetrics.thermal)
                        Divider()
                        row("Hot context", "\(model.runtimeMetrics.contextTokens) / \(model.runtimeMetrics.contextBudget)")
                    }
                    .padding(.horizontal, 16)
                    .glassEffect(.regular, in: .rect(cornerRadius: 22))

                    Text("The 27B profile memory-maps model weights and chooses Metal-resident layers from the device working-set budget while leaving headroom for iOS, the agent, WebKit previews, and the UI. Prefix reuse avoids re-prefilling unchanged prompt tokens.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 4)
                }
                .padding(16)
            }
            .navigationTitle("Performance")
            .background(Color(uiColor: .systemGroupedBackground))
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
        }
    }

    private func big(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption2.weight(.bold)).foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 28, weight: .semibold, design: .rounded))
                .minimumScaleFactor(0.7)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .glassEffect(.regular, in: .rect(cornerRadius: 22))
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).foregroundStyle(.secondary)
            Spacer(minLength: 16)
            Text(value).font(.subheadline.weight(.medium)).multilineTextAlignment(.trailing).textSelection(.enabled)
        }
        .padding(.vertical, 10)
    }
}

struct HistoryView: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("Current run checkpoints") {
                    let checkpoints = model.events.filter { $0.kind == .checkpoint }.reversed()
                    if checkpoints.isEmpty {
                        Text("Checkpoints are written after agent tool steps.").foregroundStyle(.secondary)
                    }
                    ForEach(Array(checkpoints)) { event in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(event.title).font(.subheadline.weight(.semibold))
                            Text(event.detail).font(.caption).foregroundStyle(.secondary)
                            Text(event.timestamp, style: .relative).font(.caption2).foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 3)
                    }
                }
            }
            .navigationTitle("History")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
        }
    }
}

struct SettingsView: View {
    @Bindable var model: AppModel
    @AppStorage("TriInfer.thermalGuard") private var thermalGuard = true
    @AppStorage("TriInfer.autoCompact") private var autoCompact = true
    @AppStorage("TriInfer.performanceOverlay") private var performanceOverlay = true
    @AppStorage("TriInfer.fastNoThink") private var fastNoThink = true

    var body: some View {
        Form {
            Section("Inference") {
                LabeledContent("Loaded model", value: model.currentModelName)
                Toggle("Fast /no_think mode", isOn: $fastNoThink)
                Toggle("Protect sustained speed from thermal throttling", isOn: $thermalGuard)
                Toggle("Show performance telemetry", isOn: $performanceOverlay)
            }

            Section("Long-running agent") {
                Toggle("Automatic context compaction", isOn: $autoCompact)
                LabeledContent("Guarded steps per run", value: "256")
                LabeledContent("Memory", value: "Indexed external evidence")
                LabeledContent("Workspace", value: "Sandboxed + undo")
                LabeledContent("Tool protocol", value: "Compact JSON")
            }

            Section("About") {
                LabeledContent("Runtime", value: "llama.cpp b10456 / Metal + CPU")
                LabeledContent("UI", value: "Native SwiftUI + Liquid Glass")
                LabeledContent("Version", value: "4.0")
                Text("Inference and project files stay local unless you explicitly download a model or choose an external workspace.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Settings")
    }
}

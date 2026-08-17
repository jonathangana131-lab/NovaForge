import SwiftUI

struct ChatView: View {
    @Bindable var model: AppModel
    @FocusState private var composerFocused: Bool

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 18) {
                    hero
                    ForEach(model.messages) { message in
                        MessageRow(message: message).id(message.id)
                    }
                    if model.isGenerating { GeneratingRow(model: model) }
                    Color.clear.frame(height: 108).id("bottom")
                }
                .padding(.horizontal, 16).padding(.top, 8)
            }
            .scrollDismissesKeyboard(.interactively)
            .safeAreaInset(edge: .bottom) { composer }
            .onChange(of: model.messages.count) { _, _ in withAnimation(.snappy) { proxy.scrollTo("bottom", anchor: .bottom) } }
        }
        .navigationTitle("TriInfer")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbar }
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "bolt.horizontal.circle.fill").font(.title2)
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.currentModelName).font(.headline).lineLimit(1)
                    Text(model.currentModelName == "No model loaded" ? "Choose a local model to start" : "Local • private • project-aware").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if model.currentModelName != "No model loaded" {
                    Text(model.runtimeMetrics.tokensPerSecond > 0 ? String(format: "%.1f t/s", model.runtimeMetrics.tokensPerSecond) : "Ready")
                        .font(.caption.weight(.semibold)).padding(.horizontal, 9).padding(.vertical, 5).background(.thinMaterial, in: Capsule())
                }
            }
            if model.currentModelName == "No model loaded" {
                Button { model.selectedTab = .models } label: { Label("Open Model Library", systemImage: "arrow.down.circle") }
                    .buttonStyle(.borderedProminent)
            } else {
                HStack(spacing: 8) {
                    MetricPill(title: "Prefix reused", value: "\(model.runtimeMetrics.cachedPrefixTokens) tok")
                    MetricPill(title: "Context", value: "\(model.runtimeMetrics.contextTokens) / \(model.runtimeMetrics.contextBudget)")
                }
            }
        }
        .padding(16)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).stroke(.quaternary))
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Menu {
                Picker("Agent Mode", selection: $model.agentMode) {
                    ForEach(AppModel.AgentMode.allCases) { mode in Label(mode.rawValue, systemImage: mode.symbol).tag(mode) }
                }
                Divider()
                Button("New Chat", systemImage: "square.and.pencil") { model.clearChat() }
                Button("History", systemImage: "clock.arrow.circlepath") { model.showHistory = true }
            } label: { Label(model.agentMode.rawValue, systemImage: model.agentMode.symbol).font(.subheadline.weight(.semibold)) }
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button { model.showTasks = true } label: { Image(systemName: "checklist") }
            Menu {
                Button("Context", systemImage: "brain") { model.showContext = true }
                Button("Performance", systemImage: "gauge.with.dots.needle.bottom.50percent") { model.showPerformance = true }
            } label: { Image(systemName: "ellipsis.circle") }
        }
    }

    private var composer: some View {
        VStack(spacing: 8) {
            if model.agentMode == .plan {
                HStack(spacing: 6) { Image(systemName: "lock"); Text("Plan mode is read-only").font(.caption.weight(.medium)); Spacer() }
                    .foregroundStyle(.secondary).padding(.horizontal, 6)
            }
            HStack(alignment: .bottom, spacing: 10) {
                TextField(model.currentModelName == "No model loaded" ? "Load a model first" : "Ask TriInfer to build…", text: $model.draft, axis: .vertical)
                    .lineLimit(1...6).focused($composerFocused).textFieldStyle(.plain).padding(.vertical, 10).padding(.leading, 12)
                if model.isGenerating {
                    Button(action: model.stop) { Image(systemName: "stop.fill").frame(width: 34, height: 34) }.buttonStyle(.borderedProminent).tint(.red)
                } else {
                    Button(action: model.send) { Image(systemName: "arrow.up").font(.headline).frame(width: 34, height: 34) }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.currentModelName == "No model loaded")
                }
            }
            .padding(6)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).stroke(.quaternary))
        }
        .padding(.horizontal, 12).padding(.bottom, 8)
    }
}

private struct MessageRow: View {
    let message: AppModel.ChatMessage
    var body: some View {
        HStack(alignment: .top) {
            if message.role == .user { Spacer(minLength: 44) }
            if message.role == .assistant {
                Image(systemName: "bolt.horizontal.fill").font(.caption).frame(width: 28, height: 28).background(.thinMaterial, in: Circle())
            }
            Text(message.text)
                .font(.body).textSelection(.enabled)
                .padding(message.role == .user ? 12 : 0)
                .background(message.role == .user ? AnyShapeStyle(.thinMaterial) : AnyShapeStyle(.clear), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            if message.role != .user { Spacer(minLength: 20) }
        }
        .frame(maxWidth: .infinity)
    }
}

private struct GeneratingRow: View {
    let model: AppModel
    var body: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text("Working").font(.subheadline.weight(.semibold))
            Text("•").foregroundStyle(.tertiary)
            Text(model.events.last?.title ?? "Planning next action").font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            Spacer()
        }.padding(.vertical, 6)
    }
}

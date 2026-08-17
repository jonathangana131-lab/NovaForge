import SwiftUI

struct SessionHistoryView: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var items: [SessionStore.HistoryItem] = []

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        Task { await model.startNewSession(); dismiss() }
                    } label: {
                        Label("New clean session", systemImage: "square.and.pencil")
                    }
                    .disabled(model.isGenerating)
                } footer: {
                    Text("A new session clears the hot chat context but keeps your workspace and durable project memory.")
                }

                Section("Saved checkpoints") {
                    if items.isEmpty {
                        ContentUnavailableView(
                            "No checkpoints yet",
                            systemImage: "clock.arrow.circlepath",
                            description: Text("TriInfer saves recoverable snapshots after agent tool steps.")
                        )
                    }
                    ForEach(items) { item in
                        Button {
                            Task { await model.restoreCheckpoint(item); dismiss() }
                        } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(item.title)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.primary)
                                    .lineLimit(2)
                                HStack(spacing: 8) {
                                    Text(item.updated, style: .relative)
                                    Text("•")
                                    Text("\(item.messageCount) messages")
                                    if item.todoCount > 0 {
                                        Text("•")
                                        Text("\(item.todoCount) active tasks")
                                    }
                                }
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 4)
                        }
                        .swipeActions {
                            Button(role: .destructive) {
                                Task {
                                    await model.deleteCheckpoint(item)
                                    await reload()
                                }
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                }
            }
            .navigationTitle("History")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
            }
            .task { await reload() }
            .refreshable { await reload() }
        }
    }

    private func reload() async {
        items = await model.sessions.history()
    }
}

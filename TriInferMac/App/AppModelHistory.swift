import Foundation

@MainActor
extension AppModel {
    func restoreCheckpoint(_ item: SessionStore.HistoryItem) async {
        guard !isGenerating else { return }
        guard let snapshot = await sessions.restoreHistory(item.id) else {
            alertMessage = "That checkpoint could not be restored."
            return
        }
        messages = snapshot.messages
        todos = snapshot.todos
        events = snapshot.events + [
            .init(kind: .checkpoint, title: "Checkpoint restored", detail: item.title)
        ]
        agentMode = snapshot.mode
        selectedTab = .chat
        try? await sessions.save(messages: messages, todos: todos, events: events, mode: agentMode)
    }

    func deleteCheckpoint(_ item: SessionStore.HistoryItem) async {
        await sessions.deleteHistory(item.id)
    }

    func startNewSession() async {
        guard !isGenerating else { return }
        messages = [
            .init(role: .assistant, text: "New session ready. The workspace and durable project memory stay available, but this chat starts with a clean hot context.")
        ]
        todos = []
        events = []
        agentMode = .build
        try? await context.resetConversation()
        await sessions.clearCurrent()
        try? await sessions.save(messages: messages, todos: todos, events: events, mode: agentMode)
        selectedTab = .chat
    }
}

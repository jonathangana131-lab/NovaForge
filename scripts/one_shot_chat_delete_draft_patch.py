from pathlib import Path

chat_path = Path("AgentPad/Views/ChatView.swift")
chat = chat_path.read_text()

type_anchor = "struct ChatView: View {"
if chat.count(type_anchor) != 1:
    raise SystemExit(f"expected one ChatView anchor, found {chat.count(type_anchor)}")

helper = '''final class ConversationDraftPersistence: @unchecked Sendable {
    static let shared = ConversationDraftPersistence()
    static let storageKey = "novaForgeChatDraftsByConversation"

    private let lock = NSLock()
    private var deletedConversationIDs: Set<UUID> = []

    private init() {}

    func markDeletedAndPurge(_ conversationID: UUID, defaults: UserDefaults = .standard) {
        lock.lock()
        deletedConversationIDs.insert(conversationID)
        lock.unlock()
        purge(conversationID, defaults: defaults)
    }

    func shouldPersist(_ conversationID: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return !deletedConversationIDs.contains(conversationID)
    }

    func purge(_ conversationID: UUID, defaults: UserDefaults = .standard) {
        guard let raw = defaults.string(forKey: Self.storageKey),
              let data = raw.data(using: .utf8),
              var drafts = try? JSONDecoder().decode([String: String].self, from: data),
              drafts.removeValue(forKey: conversationID.uuidString) != nil,
              let encoded = try? JSONEncoder().encode(drafts),
              let updated = String(data: encoded, encoding: .utf8) else { return }
        defaults.set(updated, forKey: Self.storageKey)
    }
}

'''
chat = chat.replace(type_anchor, helper + type_anchor, 1)

persist_start = chat.index("    private func persistDraft(_ draft: String, for conversationID: UUID) {")
persist_end = chat.index("\n    private func ", persist_start + 8)
persist_function = chat[persist_start:persist_end]
persist_anchor = "        var drafts = persistedDrafts()\n"
if persist_function.count(persist_anchor) != 1:
    raise SystemExit("persistDraft anchor was not unique")
persist_guard = '''        guard ConversationDraftPersistence.shared.shouldPersist(conversationID) else {
            ConversationDraftPersistence.shared.purge(conversationID)
            return
        }
'''
persist_function = persist_function.replace(persist_anchor, persist_guard + persist_anchor, 1)
chat = chat[:persist_start] + persist_function + chat[persist_end:]
chat_path.write_text(chat)

root_path = Path("AgentPad/Views/AppRootView.swift")
root = root_path.read_text()
delete_start = root.index("    private func deleteConversationFromHistory(_ conversationID: UUID) {")
delete_end = root.index("\n    private func ", delete_start + 8)
delete_function = root[delete_start:delete_end]
commit_anchor = "            persistenceCommitRevision &+= 1\n"
if delete_function.count(commit_anchor) != 1:
    raise SystemExit("delete success commit anchor was not unique")
delete_call = "try await store.deleteConversationFromHistory("
if delete_call not in delete_function:
    raise SystemExit("expected durable delete call in deleteConversationFromHistory")
mark_call = "            ConversationDraftPersistence.shared.markDeletedAndPurge(conversationID)\n"
delete_function = delete_function.replace(commit_anchor, mark_call + commit_anchor, 1)
if delete_function.index(mark_call.strip()) < delete_function.index(delete_call):
    raise SystemExit("draft invalidation must remain after the durable deletion call")
root = root[:delete_start] + delete_function + root[delete_end:]
root_path.write_text(root)

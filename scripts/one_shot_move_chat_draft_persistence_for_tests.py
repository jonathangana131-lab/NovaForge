from pathlib import Path

chat_path = Path("AgentPad/Views/ChatView.swift")
models_path = Path("AgentPad/Models/Models.swift")
tests_path = Path("AgentPadTests/AgentRuntimeLifecycleTests.swift")

chat = chat_path.read_text()
models = models_path.read_text()
tests = tests_path.read_text()

helper_start_token = "final class ConversationDraftPersistence: @unchecked Sendable {"
chat_view_token = "\nstruct ChatView: View {"
if chat.count(helper_start_token) != 1:
    raise SystemExit(f"expected one draft persistence helper in ChatView, found {chat.count(helper_start_token)}")
helper_start = chat.index(helper_start_token)
helper_end = chat.index(chat_view_token, helper_start)
helper = chat[helper_start:helper_end].rstrip() + "\n\n"
chat = chat[:helper_start] + chat[helper_end + 1:]
if helper_start_token in chat:
    raise SystemExit("draft helper remained in ChatView after extraction")

models_anchor = "struct WorkspaceProgressStep: Identifiable, Equatable, Sendable {"
if models.count(models_anchor) != 1:
    raise SystemExit(f"expected one Models insertion anchor, found {models.count(models_anchor)}")
if helper_start_token in models:
    raise SystemExit("draft helper already exists in Models")
models = models.replace(models_anchor, helper + models_anchor, 1)

class_anchor = "@MainActor\nfinal class AgentRuntimeLifecycleTests: XCTestCase {\n"
if tests.count(class_anchor) != 1:
    raise SystemExit(f"expected one lifecycle test class anchor, found {tests.count(class_anchor)}")

test_method = r'''    func testDeletedConversationDraftPurgesOnlyTargetAndInstallsTombstone() throws {
        let suiteName = "NovaForge.ChatDeleteDraft.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let deletedConversationID = UUID()
        let preservedConversationID = UUID()
        let encoded = try JSONEncoder().encode([
            deletedConversationID.uuidString: "discarded unsent text",
            preservedConversationID.uuidString: "preserved unsent text",
        ])
        defaults.set(
            try XCTUnwrap(String(data: encoded, encoding: .utf8)),
            forKey: ConversationDraftPersistence.storageKey
        )

        ConversationDraftPersistence.shared.markDeletedAndPurge(
            deletedConversationID,
            defaults: defaults
        )

        let raw = try XCTUnwrap(
            defaults.string(forKey: ConversationDraftPersistence.storageKey)
        )
        let data = try XCTUnwrap(raw.data(using: .utf8))
        let drafts = try JSONDecoder().decode([String: String].self, from: data)

        XCTAssertNil(drafts[deletedConversationID.uuidString])
        XCTAssertEqual(
            drafts[preservedConversationID.uuidString],
            "preserved unsent text"
        )
        XCTAssertFalse(
            ConversationDraftPersistence.shared.shouldPersist(deletedConversationID)
        )
        XCTAssertTrue(
            ConversationDraftPersistence.shared.shouldPersist(preservedConversationID)
        )
    }

'''
if "testDeletedConversationDraftPurgesOnlyTargetAndInstallsTombstone" in tests:
    raise SystemExit("chat delete draft unit test already exists")
tests = tests.replace(class_anchor, class_anchor + test_method, 1)

chat_path.write_text(chat)
models_path.write_text(models)
tests_path.write_text(tests)

#!/usr/bin/env bash
set -euo pipefail

python3 - <<'PY'
from pathlib import Path

chat = Path("AgentPad/Views/ChatView.swift").read_text()
models = Path("AgentPad/Models/Models.swift").read_text()
root = Path("AgentPad/Views/AppRootView.swift").read_text()
tests = Path("AgentPadTests/AgentRuntimeLifecycleTests.swift").read_text()
project = Path("AgentPad.xcodeproj/project.pbxproj").read_text()


def function_slice(source: str, signature: str) -> str:
    start = source.index(signature)
    next_function = source.find("\n    private func ", start + len(signature))
    if next_function == -1:
        raise SystemExit(f"could not find end of {signature}")
    return source[start:next_function]

storage_key = 'novaForgeChatDraftsByConversation'
helper_signature = 'final class ConversationDraftPersistence: @unchecked Sendable {'
if models.count(helper_signature) != 1:
    raise SystemExit("ConversationDraftPersistence must exist exactly once in shared Models.swift")
if helper_signature in chat:
    raise SystemExit("ConversationDraftPersistence must not drift back into app-only ChatView.swift")
if models.count(f'static let storageKey = "{storage_key}"') != 1:
    raise SystemExit("draft invalidation must bind the canonical composer draft storage key")
if "Models.swift in Sources" not in project or "AA0000000000000000000210 /* Models.swift in Sources */" not in project:
    raise SystemExit("Models.swift must remain compiled by the unit-test target")

helper_start = models.index(helper_signature)
helper_end = models.index("\nstruct WorkspaceProgressStep:", helper_start)
helper = models[helper_start:helper_end]
mark_start = helper.index("    func markDeletedAndPurge(")
mark_end = helper.index("\n    func shouldPersist", mark_start)
mark = helper[mark_start:mark_end]
if mark.index("deletedConversationIDs.insert(conversationID)") > mark.index("purge(conversationID, defaults: defaults)"):
    raise SystemExit("deleted conversation tombstone must be installed before purge")
if "return !deletedConversationIDs.contains(conversationID)" not in helper:
    raise SystemExit("deleted conversations must be rejected by draft persistence")
if "let storedValue = defaults.object(forKey: Self.storageKey)" not in helper:
    raise SystemExit("purge must inspect the raw stored draft value before decoding")
if "defaults.removeObject(forKey: Self.storageKey)" not in helper:
    raise SystemExit("corrupt or wrong-type draft storage must be cleared after successful deletion")
if "drafts.removeValue(forKey: conversationID.uuidString)" not in helper:
    raise SystemExit("valid draft storage must remove only the deleted conversation's draft")
corrupt_guard = "guard let raw = storedValue as? String,"
corrupt_clear = "defaults.removeObject(forKey: Self.storageKey)"
valid_remove = "drafts.removeValue(forKey: conversationID.uuidString)"
if not (helper.index(corrupt_guard) < helper.index(corrupt_clear) < helper.index(valid_remove)):
    raise SystemExit("corrupt storage must fail closed before valid target-only removal")

persist = function_slice(
    chat,
    "    private func persistDraft(_ draft: String, for conversationID: UUID) {",
)
guard_call = "guard ConversationDraftPersistence.shared.shouldPersist(conversationID) else {"
purge_call = "ConversationDraftPersistence.shared.purge(conversationID)"
drafts_load = "var drafts = persistedDrafts()"
for token in (guard_call, purge_call, drafts_load):
    if token not in persist:
        raise SystemExit(f"persistDraft is missing required contract token: {token}")
if not (persist.index(guard_call) < persist.index(purge_call) < persist.index(drafts_load)):
    raise SystemExit("persistDraft must reject and re-purge deleted chats before reading/writing draft storage")

switch_anchor = ".onChange(of: conversation.id) { oldValue, _ in"
flush_anchor = "flushDraftPersistence(prompt, for: oldValue)"
if switch_anchor not in chat or flush_anchor not in chat:
    raise SystemExit("selected-chat reroute flush path must remain represented by this regression contract")
switch_start = chat.index(switch_anchor)
if chat.find(flush_anchor, switch_start, switch_start + 500) == -1:
    raise SystemExit("conversation switch must still flush the old draft through guarded persistence")

delete = function_slice(
    root,
    "    private func deleteConversationFromHistory(_ conversationID: UUID) {",
)
durable_delete = "try await store.deleteConversationFromHistory("
catch_return = "showRootSaveFailure(\"Could not delete this chat.\", error)\n                return"
mark_deleted = "ConversationDraftPersistence.shared.markDeletedAndPurge(conversationID)"
commit_revision = "persistenceCommitRevision &+= 1"
for token in (durable_delete, catch_return, mark_deleted, commit_revision):
    if token not in delete:
        raise SystemExit(f"deleteConversationFromHistory is missing required contract token: {token}")
if delete.count(mark_deleted) != 1:
    raise SystemExit("successful deletion must invalidate the draft exactly once")
if not (delete.index(durable_delete) < delete.index(catch_return) < delete.index(mark_deleted) < delete.index(commit_revision)):
    raise SystemExit("draft invalidation must happen only after durable deletion failure has returned, and before reroute commit")

valid_unit_test = "func testDeletedConversationDraftPurgesOnlyTargetAndInstallsTombstone() throws {"
if tests.count(valid_unit_test) != 1:
    raise SystemExit("valid-storage chat-delete draft regression must exist exactly once")
for token in (
    "ConversationDraftPersistence.shared.markDeletedAndPurge(",
    "XCTAssertNil(drafts[deletedConversationID.uuidString])",
    "drafts[preservedConversationID.uuidString]",
    "XCTAssertFalse(",
    "XCTAssertTrue(",
):
    if token not in tests:
        raise SystemExit(f"valid-storage executable regression is missing: {token}")

corrupt_unit_test = "func testDeletedConversationDraftClearsMalformedStorageAndInstallsTombstone() throws {"
if tests.count(corrupt_unit_test) != 1:
    raise SystemExit("malformed-storage chat-delete regression must exist exactly once")
corrupt_test_start = tests.index(corrupt_unit_test)
corrupt_test_end = tests.index("\n    func ", corrupt_test_start + len(corrupt_unit_test))
corrupt_test = tests[corrupt_test_start:corrupt_test_end]
for token in (
    '"{malformed-draft-json"',
    "ConversationDraftPersistence.shared.markDeletedAndPurge(",
    "defaults.object(forKey: ConversationDraftPersistence.storageKey)",
    "XCTAssertFalse(",
):
    if token not in corrupt_test:
        raise SystemExit(f"malformed-storage executable regression is missing: {token}")

for temporary_path in (
    ".github/workflows/one-shot-chat-delete-draft-patch.yml",
    "scripts/one_shot_chat_delete_draft_patch.py",
    ".github/workflows/one-shot-chat-delete-draft-testability.yml",
    "scripts/one_shot_move_chat_draft_persistence_for_tests.py",
    ".github/workflows/one-shot-chat-delete-corrupt-draft.yml",
    "scripts/one_shot_chat_delete_corrupt_draft_patch.py",
):
    if Path(temporary_path).exists():
        raise SystemExit(f"temporary mutation helper leaked into the permanent branch: {temporary_path}")

print("PASS: Preview chat deletion purges valid drafts narrowly, clears corrupt storage after durable success, blocks selected-chat resurrection, and is wired to executable XTests.")
PY

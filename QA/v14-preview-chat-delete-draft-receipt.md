# V14 Preview Chat Delete Draft Durability Receipt

Protocol: NF-SWARM-v14  
Worker: `GPT56-SOL-NF-V14-PREVIEW-CHAT-DELETE-DRAFT-0810`  
Base: `main@991ece0ed9add9acf1108055f489b25f6cc9843f`  
Branch: `gpt56-sol-preview-chat-delete-draft-0810`  
PR: `#255`

## Preview defect

`ChatView` persists unsent composer text per conversation in `UserDefaults` under `novaForgeChatDraftsByConversation`. `AppRootView.deleteConversationFromHistory(_:)` durably deleted the SwiftData conversation but did not remove that conversation's stored draft.

That left user-authored chat data behind after the drawer confirmed that deleting the chat from history could not be undone.

A second edge made a simple post-delete `UserDefaults` removal insufficient: when the currently visible chat is deleted, `ChatView.onChange(of: conversation.id)` flushes the old prompt during reroute. Without a tombstone, that teardown flush can recreate the draft after it was purged.

Independent adversarial review `4902379276` then found a further P1 corruption edge: if the shared draft payload was malformed, the first purge implementation returned without deleting anything. The conversation could therefore be durably deleted while undecodable user-authored draft bytes remained stored indefinitely.

## Repair

Successful chat deletion is now authoritative for draft invalidation:

1. `SwiftDataAgentStore.deleteConversationFromHistory(...)` executes first.
2. The existing `catch` path reports a failed delete and returns without touching draft storage.
3. After durable deletion succeeds, `ConversationDraftPersistence.shared.markDeletedAndPurge(conversationID)` installs an in-process tombstone and purges persisted draft data.
4. For a valid `[String: String]` draft dictionary, purge removes only the deleted conversation key and preserves other conversations' drafts.
5. For malformed or wrong-type data under the canonical draft-storage key, purge fails closed by removing that unusable storage value. Existing composer loading already treats absent/corrupt storage as no saved drafts, so this does not create a new readable-data loss mode; it prevents corrupt user-authored bytes surviving a successful destructive action.
6. `ChatView.persistDraft` checks the tombstone before reading/writing storage, so a late selected-chat teardown flush cannot resurrect the deleted draft.

`ConversationDraftPersistence` lives in `AgentPad/Models/Models.swift`, already compiled by both app and unit-test targets. No `project.pbxproj` mutation was required.

The tombstone only needs process lifetime: the resurrection risk exists while the old `ChatView` is still alive during the same-process reroute. The persisted value itself is removed or rewritten durably after successful deletion.

## Failure semantics

Draft cleanup remains after the awaited SwiftData delete and after the failure `catch` return. A storage failure therefore preserves unsent text along with the not-deleted conversation instead of losing user text on an unsuccessful destructive action.

Corrupt-storage clearing happens only after the conversation delete succeeds.

## Exact mutation evidence

Large concurrently active Swift files were changed through the repository's established branch-only one-shot Actions mutation pattern:

- exact source anchors are validated;
- only intended locations are patched;
- `git diff --check` and source assertions run before commit;
- temporary workflow/script files remove themselves from the permanent branch.

Initial product commit `f1b6b864a94a9803c9f82ec3886f14a84db90644` added successful-delete invalidation and selected-chat anti-resurrection. Commit `d450ef7d6e18a73e32198b02b5ce550b971f7796` moved the helper into shared `Models.swift` and added executable XCTest coverage. Review-blocker repair commit `c7a8a5c445be6443fb5d63475de15f791fc3846e` added fail-closed corrupt-storage clearing and its malformed-payload regression.

No one-shot mutation helper remains in the permanent branch state.

## Executable regressions

`AgentPadTests/AgentRuntimeLifecycleTests.swift` includes:

- `testDeletedConversationDraftPurgesOnlyTargetAndInstallsTombstone()` — proves a valid draft dictionary loses only the deleted conversation, preserves an unrelated draft, tombstones the deleted UUID, and leaves an unrelated UUID persistable.
- `testDeletedConversationDraftClearsMalformedStorageAndInstallsTombstone()` — writes malformed JSON into an isolated `UserDefaults` suite, performs successful-delete draft invalidation, then proves the corrupt storage value is absent and the deleted UUID is tombstoned.

Fresh UUIDs avoid cross-test coupling from the intentionally process-lifetime tombstone set.

## Durable regression contract

`script/verify` coverage is persisted in:

- `scripts/verify_v14_preview_chat_delete_draft_contract.sh`
- `.github/workflows/v14-preview-chat-delete-draft-contract.yml`

The contract fails if:

- invalidation stops binding the canonical composer-draft storage key;
- the helper moves out of shared `Models.swift` or that source stops being unit-test compiled;
- the tombstone is removed or installed after purge;
- corrupt/wrong-type storage is no longer cleared;
- valid storage stops removing only the target conversation key;
- `persistDraft` can touch storage before rejecting a deleted conversation;
- selected-chat reroute no longer flushes through guarded persistence;
- invalidation moves before durable-delete failure has returned or after the post-delete routing commit point;
- either executable regression disappears or loses its required assertions;
- temporary one-shot mutation helpers leak into the permanent branch.

## Exact validation evidence

Review-blocker validation head: `4e1f582a221888cf1d53a5c28240fddb2a013761`.

- `V14 Preview chat delete draft contract` run `31451229415`: **SUCCESS**.
- Repository `CI` run `31451229409`: **QUEUED** at this receipt update.

The dedicated contract therefore proves the source ordering, valid/corrupt storage branches, anti-resurrection wiring, unit-test presence/wiring, and temporary-file cleanup at the review-blocker validation head. The macOS CI runner has not yet executed the XCTest on that head.

## Truth boundary

This receipt does **not** claim the XCTest executed successfully, a full app compile, iOS 27 Simulator interaction, physical iPhone 12 evidence, visual acceptance, accessibility acceptance, or performance acceptance until those corresponding validation layers actually report success.

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

## Repair

The repair makes successful chat deletion authoritative for draft invalidation:

1. `SwiftDataAgentStore.deleteConversationFromHistory(...)` still executes first.
2. The existing `catch` path still reports the failed delete and returns. It does not purge the draft.
3. After durable deletion succeeds, `ConversationDraftPersistence.shared.markDeletedAndPurge(conversationID)` installs an in-process tombstone and removes that conversation key from the canonical draft dictionary.
4. `ChatView.persistDraft` checks the tombstone before loading or writing draft storage. A late selected-chat teardown flush therefore re-purges and returns instead of resurrecting the deleted draft.
5. Other conversations' drafts remain untouched.

`ConversationDraftPersistence` now lives in `AgentPad/Models/Models.swift`, which the existing Xcode project already compiles into both the app and unit-test targets. That keeps the behavior testable without changing `project.pbxproj` or widening app dependencies.

The tombstone only needs process lifetime: the resurrection risk exists while the old `ChatView` is still alive during the same-process reroute. The durable `UserDefaults` entry itself is removed on successful deletion.

## Failure semantics

Draft cleanup is intentionally after the awaited SwiftData delete and after the failure `catch` return. A storage failure therefore preserves the unsent draft along with the not-deleted conversation instead of losing user text on an unsuccessful destructive action.

## Exact mutation evidence

The production views are large and concurrently active in the Preview swarm. To avoid whole-file connector replacement, this worker used the repository's established branch-only one-shot Actions mutation pattern:

- validate exact source anchors;
- patch only the intended source locations;
- run `git diff --check` and source assertions;
- commit the product/test repair;
- delete each temporary workflow and patch script in the same resulting product commit.

Initial product commit `f1b6b864a94a9803c9f82ec3886f14a84db90644` changed only `AppRootView.swift` (+1) and `ChatView.swift` (+37) against the claimed base. Follow-up commit `d450ef7d6e18a73e32198b02b5ce550b971f7796` moved the helper into already-shared `Models.swift` and added an executable XCTest without touching `project.pbxproj`.

No temporary one-shot file remains in the permanent branch state.

## Executable regression

`AgentPadTests/AgentRuntimeLifecycleTests.swift` now includes `testDeletedConversationDraftPurgesOnlyTargetAndInstallsTombstone()`.

Using an isolated `UserDefaults` suite and fresh UUIDs, it verifies that:

- the deleted conversation's draft disappears;
- another conversation's draft remains byte-for-byte meaningful;
- the deleted UUID is tombstoned from future persistence;
- an unrelated UUID remains eligible for persistence.

The unique UUIDs avoid cross-test coupling from the intentionally process-lifetime tombstone set.

## Durable regression contract

Added/strengthened:

- `scripts/verify_v14_preview_chat_delete_draft_contract.sh`
- `.github/workflows/v14-preview-chat-delete-draft-contract.yml`

The contract fails if:

- draft invalidation stops binding the canonical composer-draft storage key;
- the helper moves out of `Models.swift` or `Models.swift` stops being compiled into the unit-test target;
- the deleted-conversation tombstone is removed;
- purge stops deleting only the target conversation key;
- `persistDraft` can read/write storage before rejecting a deleted conversation;
- the selected-chat reroute no longer routes its old-prompt flush through guarded persistence;
- deletion invalidates a draft before the durable store call can fail and return;
- invalidation moves after the post-delete routing commit point;
- the executable XCTest disappears or loses its target/preserved draft assertions;
- a temporary one-shot mutation helper leaks into the permanent branch.

## Current exact-head evidence

At head `0f36cbd1be771164e298cfa8a855f022f4875dbd`:

- `V14 Preview chat delete draft contract` run `31450986466`: **SUCCESS**.
- Repository `CI` run `31450986464`: **QUEUED** at the time of this receipt update.

Therefore the source-level contract and executable-test wiring are proven at this head, but the XCTest itself is not yet claimed green until the macOS CI runner executes it.

## Truth boundary

This receipt proves the source-level durability ordering, selected-chat anti-resurrection guard, target-scoped draft purge behavior represented by XCTest, shared-source test wiring, and the green exact-head static CI contract.

It does **not** claim the XCTest executed successfully, a full app compile, iOS 27 Simulator interaction evidence, physical iPhone 12 evidence, or visual acceptance until those corresponding CI/runtime layers actually report success.

# V14 Preview Chat Delete Draft Durability Receipt

Protocol: NF-SWARM-v14  
Worker: `GPT56-SOL-NF-V14-PREVIEW-CHAT-DELETE-DRAFT-0810`  
Base: `main@991ece0ed9add9acf1108055f489b25f6cc9843f`  
Branch: `gpt56-sol-preview-chat-delete-draft-0810`

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

The tombstone only needs process lifetime: the resurrection risk exists while the old `ChatView` is still alive during the same-process reroute. The durable `UserDefaults` entry itself is removed on successful deletion.

## Failure semantics

Draft cleanup is intentionally after the awaited SwiftData delete and after the failure `catch` return. A storage failure therefore preserves the unsent draft along with the not-deleted conversation instead of losing user text on an unsuccessful destructive action.

## Exact mutation evidence

The two production files are large and concurrently active in the Preview swarm. To avoid whole-file connector replacement, this worker used the repository's established branch-only one-shot Actions mutation pattern:

- validate exact source anchors;
- patch only the intended source locations;
- run `git diff --check` and source assertions;
- commit the product repair;
- delete the temporary workflow and patch script in the same product commit.

At product commit `f1b6b864a94a9803c9f82ec3886f14a84db90644`, comparison against the claimed base shows only:

- `AgentPad/Views/AppRootView.swift`: `+1/-0`;
- `AgentPad/Views/ChatView.swift`: `+37/-0`.

No temporary one-shot file remains in the net branch diff.

## Durable regression contract

Added:

- `scripts/verify_v14_preview_chat_delete_draft_contract.sh`
- `.github/workflows/v14-preview-chat-delete-draft-contract.yml`

The contract fails if:

- draft invalidation stops binding the canonical composer-draft storage key;
- the deleted-conversation tombstone is removed;
- purge stops deleting only the target conversation key;
- `persistDraft` can read/write storage before rejecting a deleted conversation;
- the selected-chat reroute no longer routes its old-prompt flush through guarded persistence;
- deletion invalidates a draft before the durable store call can fail and return;
- invalidation moves after the post-delete routing commit point;
- a temporary one-shot mutation helper leaks into the permanent branch.

## Truth boundary

This receipt proves the source-level durability ordering, the selected-chat anti-resurrection guard, the narrow net diff, and the permanent static CI contract once its PR workflow passes.

It does **not** claim iOS 27 Simulator interaction evidence, physical iPhone 12 evidence, visual acceptance, or a full app compile solely from these source assertions. Those remain separate Preview acceptance layers.

# V14 Preview Stop / Cancel Recovery Contract Receipt

Protocol: NF-SWARM-v14  
Worker: `GPT56-SOL-NF-V14-PREVIEW-STOP-CANCEL-0814`  
Base: `main@f319f6ceee5513b46d87e948b7a6ffb993e879ac`  
Branch: `gpt-5-6-sol/preview-stop-cancel-contract`  
PR: `#277`

## Preview acceptance gap

The V14 Preview acceptance checklist requires Stop/cancel recovery, but the refreshed `main` tree did not have a dedicated permanent Preview contract tying that acceptance item to the existing production wiring and cancellation/reentry regressions.

This lane does not change cancellation behavior. It makes the existing behavior fail closed in CI if the visible Stop wiring or the relevant executable regression evidence is later removed or split into an unguarded path.

## Protected wiring

`scripts/verify_v14_preview_stop_cancel_recovery.sh` verifies these source contracts:

1. `ComposerLiveRunRail` keeps its visible Stop affordance bound to the single `ChatView.stopActiveRun` authority.
2. When an orchestration presentation is active, `stopActiveRun` calls `AgentSystemPresentationStore.cancelOrchestration(scope:)` and returns before the normal runtime fallback can execute.
3. The normal non-orchestration fallback remains `runtime.stopGenerating(context: modelContext)`.
4. Canonical activity `.cancel` commands continue through `agentSystemPresentation.route(command)` rather than bypassing presentation command routing.

The guard deliberately preserves the distinction between orchestration cancellation, canonical activity-command cancellation, and the normal runtime Stop fallback instead of pretending they are one implementation path.

## Executable regressions bound by the contract

The verifier requires the existing XCTest evidence to remain present with its material assertions:

- `AgentRuntimeLifecycleTests.testStopGeneratingActiveRunClearsQueuedFollowUpsAndWorkingState()` — active Stop clears working state and queued follow-ups and records interruption.
- `AgentRuntimeLifecycleTests.testStopGeneratingRejectsPendingApprovalRun()` — Stop with a model context clears the pending tool, stops working, durably rejects the tool run with cancellation output, and sets completion time.
- `AgentRuntimeLifecycleTests.testCancelledStaleTaskCannotUntrackFreshStreamingRun()` — a cancelled predecessor cannot clear the tracked task of a fresh streaming run.
- `AgentRuntimeLifecycleTests.testStaleAsyncCompletionCannotOverwriteFreshRunState()` — delayed completion from cancelled work cannot overwrite a fresh run.
- `AgentSystemPresentationStoreTests.testUltraCodeCancelDuringCloneStartsNothingAndCleansAfterCancellation()` — orchestration cancellation during clone starts no agent work, cleans the workspace, reaches finite cancelled state, and releases blocking activity.
- `AgentExecutionCoordinatorTests.testCancelledQueuedRunCannotBlockImmediateNextRun()` — cancelled mutation and local-inference waiters vacate both queues so the immediate next run acquires both resources and settles with no stranded work.

The dedicated workflow is `.github/workflows/v14-preview-stop-cancel-recovery.yml` and runs the verifier on pull requests and `main` changes touching the guarded wiring/tests.

## Adversarial contract correction

The first dedicated run, `31779591956` on head `2b996a7b19e61720091a74ee5825ce555e8495e1`, **failed**. The failure was in this new contract, not in NovaForge product behavior: the verifier incorrectly required `testStopGeneratingRejectsPendingApprovalRun()` to assert `runtime.runState == .cancelled`.

The executable regression does not promise that state-field assertion. Its durable pending-approval cancellation facts are the pending tool removal, stopped working state, rejected `ToolRun`, persisted `"Cancelled while waiting for approval."` output, and non-nil completion timestamp.

Commit `95ea3e9602cef9baf41f58de8244e68090807d72` removed the invented state requirement and replaced it with the actual durable assertions already covered by the XCTest.

Dedicated run `31779712232` on `95ea3e9602cef9baf41f58de8244e68090807d72`: **SUCCESS**.

Repository `CI` run `31779712142` on the same head: **PENDING** at receipt creation.

## Truth boundary

This is source/contract evidence plus a successful Ubuntu GitHub Actions verifier run. It does **not** claim:

- the referenced XTests executed in this dedicated Ubuntu job;
- an iOS 27 Simulator Stop interaction;
- physical iPhone 12 Stop/cancel behavior;
- live provider-network cancellation behavior;
- visual acceptance;
- accessibility acceptance;
- performance/frame-pacing acceptance;
- full Preview release readiness.

Those remain separate acceptance layers. The local worker container could not resolve GitHub for a clone, so no local-clone test result is claimed; GitHub Actions is the executable evidence source for this lane.

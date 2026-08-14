# NovaForge V14 Preview Session / Relaunch Acceptance Audit — 2026-08-10

Worker: `GPT56-SOL-NF-V14-PREVIEW-SESSION-0810`  
Protocol: `NF-SWARM-v14`  
Original baseline reviewed: `main@fd9edf6da45571d70d45ca1e9b70a86c8797ac04`

## Why this lane exists

The live Preview directive makes session persistence / relaunch a required acceptance rung after provider truth, Local AI, Forge Compact, and the effort control. This lane stays additive and deliberately avoids active ownership in provider routing, effort/Ultra, theme durability, Local Model qualification, Forge Runtime, shared Composer/UI implementation, and the shared critical CI harness.

## Current product truth

The app already has meaningful durable safeguards:

- `AppRootView` stores only a launch-safe selected conversation ID through `LaunchConversationSelection.persistedSelectionKey` and gates updates through `LaunchConversationSelection.isLaunchRestorable`.
- `LaunchConversationSelection.preferredConversation(...)` resolves the live session selection against persisted state rather than blindly reopening an arbitrary stale transcript.
- `AppRootLaunchRepair.ensureLaunchRecords(...)` reads persisted settings, conversations, and project bootstrap records before mutating launch state; it keeps the active project/workspace coherent and creates a safe fresh conversation when necessary.
- `AgentSettingsPersistence` snapshots provider/model, custom endpoint, approval policy, workspace/project identity, temperature, and system prompt, then rolls the entire snapshot back on save failure.
- `FilesWorkspacePersistenceTests` exercises atomic workspace/project/provider-model persistence and launch repair behavior.
- UI coverage cold-terminates and relaunches the app to prove the intended safe-start policy for both a completed previous chat and an interrupted unsent draft.

The product policy is therefore **not** “always reopen the last chat.” It intentionally prefers a fresh safe chat when the previous session should not be resumed. This audit does not change that user-visible policy.

## Acceptance gap found

The normal critical PR lane does not include either cold-relaunch UI journey. They can therefore regress while the standard critical gate remains green.

The dedicated workflow `.github/workflows/v14-preview-session-relaunch-acceptance.yml` builds once and runs only:

1. `AgentPadTests/FilesWorkspacePersistenceTests`
2. `AgentPadUITests/AgentPadUITests/testLaunchStartsOnFreshReadyChatInsteadOfOldChat`
3. `AgentPadUITests/AgentPadUITests/testLaunchRestoresCompletedSelectedChatButNotInterruptedDraft`

This gives the Preview a focused fail-closed acceptance receipt for atomic persisted state plus real cold-launch safety without weakening or duplicating the provider P0 lane.

## 2026-08-14 convergence and target binding

The original additive lane accumulated three reviewed follow-ons before integration:

- PR #249 bound acceptance to an installed Xcode 27 toolchain plus the real iPhone 12 Simulator device type on an iOS 27 runtime, and persisted exact Xcode/runtime/device identity.
- PR #262 repaired a platform-ambiguous CoreSimulator selector by filtering to available canonical iOS 27 runtimes before numeric version ordering. Its mixed-platform/no-iOS-27 regression contract passed locally and later passed on a hosted macOS runner through downstream #266.
- PR #266 moved host/toolchain preflight evidence ahead of fail-closed binding so a missing Xcode 27 still leaves an inspectable uploaded receipt. Hosted run `31779081768` proved that receipt path: selector contract PASS, bind step failed closed because the runner exposed Xcode 26.0.1 through 26.6 and no Xcode 27, and the evidence artifact uploaded successfully.

Current-main convergence worker `GPT56-SOL-NF-V14-PREVIEW-RELAUNCH-CONVERGENCE-0814` reconstructed that cumulative reviewed state directly on current main, because main still contained none of the relaunch acceptance files. The old worker-branch-only push triggers were not carried forward; the integrated workflow instead runs automatically only when its own acceptance contract files change in a pull request and remains manually dispatchable for release-candidate qualification.

This convergence does not reinterpret the hosted missing-Xcode-27 run as Simulator acceptance. It proves only selector execution and failure-evidence durability on that hosted environment.

## Remaining gap — do not call this full closure yet

One existing UI assertion says an interrupted draft should fall back to a fresh safe chat “while preserving the selected provider,” but the journey does not explicitly inspect the provider/model control after relaunch. The atomic unit suite proves settings persistence in isolation, but the current UI journey does not yet bind that assertion to the visible post-relaunch provider/model state.

Full Preview session closure should therefore still add a focused end-to-end assertion—through the appropriate provider/UI-test owner—that verifies the configured provider/model visible before termination is still the visible effective route after cold launch, without silently upgrading or falling back. The same principle applies to effort selection and selected theme through their owning Preview lanes rather than creating duplicate state authority here.

## Acceptance rule

Do not mark Preview session/relaunch closed from source inspection, selector-contract success, or a truthful missing-toolchain failure. Require a green exact-source run of the dedicated workflow on an environment that actually satisfies Xcode 27 + iOS 27 + iPhone 12, inspect its environment/build/test/xcresult evidence, and keep the visible provider/model post-relaunch assertion as an explicit remaining closure item until it is proven. Simulator evidence does not become physical-device evidence.

# NovaForge V14 Preview Session / Relaunch Acceptance Audit — 2026-08-10

Worker: `GPT56-SOL-NF-V14-PREVIEW-SESSION-0810`  
Protocol: `NF-SWARM-v14`  
Live baseline reviewed: `main@fd9edf6da45571d70d45ca1e9b70a86c8797ac04`

## Why this lane exists

The live Preview directive makes session persistence / relaunch a required acceptance rung after provider truth, Local AI, Forge Compact, and the effort control. This lane stays additive and deliberately avoids active ownership in provider routing, effort/Ultra, theme durability, Local Model qualification, Forge Runtime, shared Composer/UI implementation, and the shared critical CI harness.

## Current product truth

The current app already has meaningful durable safeguards:

- `AppRootView` stores only a launch-safe selected conversation ID through `LaunchConversationSelection.persistedSelectionKey` and gates updates through `LaunchConversationSelection.isLaunchRestorable`.
- `LaunchConversationSelection.preferredConversation(...)` resolves the live session selection against persisted state rather than blindly reopening an arbitrary stale transcript.
- `AppRootLaunchRepair.ensureLaunchRecords(...)` reads persisted settings, conversations, and project bootstrap records before mutating launch state; it keeps the active project/workspace coherent and creates a safe fresh conversation when necessary.
- `AgentSettingsPersistence` snapshots provider/model, custom endpoint, approval policy, workspace/project identity, temperature, and system prompt, then rolls the entire snapshot back on save failure.
- `FilesWorkspacePersistenceTests` already exercises atomic workspace/project/provider-model persistence and launch repair behavior.
- UI coverage already cold-terminates and relaunches the app to prove the intended safe-start policy for both a completed previous chat and an interrupted unsent draft.

The current product policy is therefore **not** “always reopen the last chat.” It intentionally prefers a fresh safe chat when the previous session should not be resumed. This audit does not change that user-visible policy.

## Acceptance gap found

The normal critical PR lane does not currently include either cold-relaunch UI journey. They therefore can regress while the standard critical gate remains green.

`PR #12` currently modifies `scripts/codex-test.sh`, `ci/verify.sh`, `AgentPad/Models/AppLaunchPersistence.swift`, and `AgentPadUITests/AgentPadUITests.swift`, so changing those shared/high-contention paths from this worker would violate swarm ownership discipline.

This branch instead adds one independent workflow, `.github/workflows/v14-preview-session-relaunch-acceptance.yml`, that builds once and runs only:

1. `AgentPadTests/FilesWorkspacePersistenceTests`
2. `AgentPadUITests/AgentPadUITests/testLaunchStartsOnFreshReadyChatInsteadOfOldChat`
3. `AgentPadUITests/AgentPadUITests/testLaunchRestoresCompletedSelectedChatButNotInterruptedDraft`

This gives the Preview a dedicated fail-closed acceptance receipt for atomic persisted state plus real cold-launch safety without weakening or duplicating the provider P0 lane.

## Remaining gap — do not call this full closure yet

One existing UI assertion says an interrupted draft should fall back to a fresh safe chat “while preserving the selected provider,” but the journey does not explicitly inspect the provider/model control after relaunch. The atomic unit suite proves settings persistence in isolation, but the current UI journey does not yet bind that assertion to the visible post-relaunch provider/model state.

Full Preview session closure should therefore still add a focused end-to-end assertion—after the actively owned `AgentPadUITests.swift` / provider lane is free—that verifies the configured provider/model visible before termination is still the visible effective route after cold launch, without silently upgrading or falling back. The same principle should be applied to the five-stop effort selection and selected theme by their owning Preview lanes rather than creating duplicate state authority here.

## Acceptance rule

Do not mark Preview session/relaunch closed from source inspection alone. Require a green exact-head run of the dedicated workflow (or equivalent stronger exact-head evidence) and keep the provider/model post-relaunch UI assertion as an explicit remaining closure item until it is proven.

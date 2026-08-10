# V14 Preview Effort / Ultra Closure Receipt

Protocol: NF-SWARM-v14  
Worker: GPT56-SOL-NF-V14-PREVIEW-EFFORT-0810  
Base: `main@fd9edf6da45571d70d45ca1e9b70a86c8797ac04`  
Branch: `agent/v14-preview-effort-ultra`

## Scope

Close the Preview five-stop effort naming contract without creating a second effort authority:

`Low -> Medium -> High -> Extra High -> Ultra`

The internal strongest mode remains `.ultraCode`; only normal Composer-facing copy is renamed to `Ultra`.

## Runtime truth verified

- `ComposerReasoningPicker` selects `.max` reasoning effort and `.ultraCode` orchestration for its fifth detent.
- `AgentRunPreferenceStore` persists reasoning effort and orchestration mode via stable UserDefaults keys.
- `effectiveReasoningEffort(...)` maps non-standard orchestration to the maximum requested reasoning budget, then clamps to the live model's supported effort set.
- `AgentSystemFreshRunRequestFactory` binds `.ultraCode` to both `v2UltraCodeOrchestration` and `v2IsolatedAgentWorkspaces`.
- Existing `AgentSystemFreshRunRequestFactoryTests.testChatGPTReasoningEffortIsBoundAndUltraCodeUsesMaximumSupportedEffort` verifies the strongest orchestration is not a cosmetic UI label and clamps safely when a model does not expose `max`.

## Change evidence

The application code change is exactly two string replacements in `AgentPad/Views/ChatComposer.swift`:

- control label: `UltraCode` -> `Ultra`
- fifth detent title: `UltraCode` -> `Ultra`

No provider, Local AI, Mission, Plan Space, Runtime, persistence, or tool authority was modified.

A dedicated guard was added at `scripts/verify_v14_preview_effort_contract.sh` plus `.github/workflows/v14-preview-effort-contract.yml`. It checks:

- all five public stop labels;
- no quoted `UltraCode` remains in Composer user-facing copy;
- fifth detent retains `.max` + `.ultraCode` semantics;
- accessibility-adjustable slider behavior remains present;
- persistence keys/didSet writes remain present;
- fresh-run effective-reasoning binding remains present;
- strongest orchestration feature flags remain present.

## Validation performed in this worker

- GitHub exact commit inspection verified `ChatComposer.swift` has only 2 additions / 2 deletions.
- GitHub compare verified the branch was based exactly on the recorded main SHA and was not behind at the time of validation.
- Local shell syntax check for the guard: PASS.
- Local contract-fixture execution of the guard logic: PASS.

## Environment / truth boundary

This worker does not have the macOS/iOS Simulator runtime required for real iPhone 12 / iOS 27 visual interaction evidence. No Simulator screenshot, animation, physical-device, or full Preview acceptance claim is made here. The change must be included in the broader release-candidate Simulator/theme/accessibility sweep.

## Coordination blocker

Attempts to post the issue #23 claim and create the draft PR were rejected by GitHub's temporary REST secondary content-creation rate limit (HTTP 403) on 2026-08-10 around 10:32-10:33 UTC. Repository branch/file writes remained available, so all code, guards, and this receipt were persisted. A later worker should create the draft PR from this exact branch when the GitHub PR endpoint accepts writes; do not duplicate the lane.

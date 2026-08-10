# NovaForge V14 Preview Effort Authority Audit — 2026-08-10

Worker: `GPT56-SOL-NF-V14-PREVIEW-EFFORT-0810`  
Reviewed live baseline: `main@fd9edf6da45571d70d45ca1e9b70a86c8797ac04`

## Result

**P1 — do not promote a second user-facing effort authority into the Preview without an explicit adapter/migration contract.**

The accepted Preview directive defines one visible five-stop effort control:

`Low -> Medium -> High -> Extra High -> Ultra`

It also explicitly says to preserve the current `AgentRunPreferenceStore` path and not create a second competing effort authority.

Current production already has that authority boundary:

- `AgentRunPreferenceStore` durably persists provider reasoning effort plus orchestration mode.
- `ComposerReasoningControl` reads/writes that store.
- the top detent selects `.max` plus `.ultraCode` internally.
- `AgentSystemFreshRunRequestFactory` consumes the same store at fresh-run construction.
- provider/model native reasoning is bounded through `effectiveReasoningEffort(...)` rather than assumed.
- internal `.ultraCode` enables `v2UltraCodeOrchestration` and `v2IsolatedAgentWorkspaces`.

The internal identifier may remain `ultraCode`; the normal user-facing fifth stop should be `Ultra`.

## Active branches reviewed

### 1. `worker/GPT56-SOL-NF-V14-EFFORT-8A10/agent-effort/e1`

Adds public `AgentEngineEffortMode` with four cases:

`fast / balanced / deep / ultra`

and maps them directly to model-round ceilings:

`32 / 128 / 256 / 512`.

Its source calls these values **user-facing NovaForge execution effort presets**, and its tests persist the enum through Codable round trips.

This is useful bounded-runtime policy in isolation, but it must not become a second persisted user preference for Preview. Its four-level vocabulary also cannot represent the canonical five Preview stops losslessly.

### 2. `worker/GPT56-SOL-NF-V14-EFFORT-0810/effort-policy/e1`

Adds public `ForgeEffortLevel` with four cases:

`fast / balanced / deep / ultra`

plus durable `ForgeEffortIntent`, host work-amplification strategy, and native-reasoning projection. Its source likewise describes the level as user-facing.

The provider-support boundary is appropriately cautious, but the persisted four-level user intent still competes with the already-live five-stop Preview state unless it is made an internal/2.0-only model with an explicit migration/adapter boundary.

## Required closure before promotion

1. Keep **one canonical persisted user selection** for Preview.
2. Treat any new runtime budget/host strategy type as a **derived internal policy**, not a second user preference.
3. If a new 2.0 effort domain is desired, define an explicit migration from current Preview state and do not cut over until the rewrite authority is ready.
4. Add deterministic tests covering all five current Preview stops and proving each maps to:
   - provider/model-bounded native reasoning where supported;
   - host/orchestration strategy;
   - a bounded runtime budget;
   - the same effective behavior after persistence/relaunch.
5. Prove provider/model changes cannot silently upgrade beyond exact capability support.
6. Preserve the existing top-stop truth: `Ultra` is presentation; `.ultraCode` may remain the internal orchestration identifier while its real isolated-workspace/integrator behavior exists.

## Collision / donor note

A presentation-only patch was independently reproduced against the reviewed live main while auditing the lane. Once another Preview-Ultra worker appeared, no duplicate PR was opened.

Donor branch: `worker/GPT56-SOL-NF-V14-PREVIEW-EFFORT-0810/ultra-label/e2`  
Product commit: `9d3aa0f`  
Temporary patch runner cleanup: `ab91f7f`

The donor changes only the four public-facing `UltraCode` string literals in `AgentPad/Services/AIProvider.swift` and `AgentPad/Views/ChatComposer.swift` to `Ultra`; internal orchestration identifiers/features remain unchanged. GitHub Actions run `31379491857` verified the exact two-file change scope and `git diff --check` before the worker detected the owner collision.

This branch is reference/donor evidence only unless the active owner needs it.

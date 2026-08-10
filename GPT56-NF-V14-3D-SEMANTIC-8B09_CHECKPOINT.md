# GPT56-NF-V14-3D-SEMANTIC-8B09 checkpoint

Protocol: NF-SWARM-v14  
Lane: `forge3d-generated-runtime-semantic-self-play-compat`  
Claim: issue #23 comment `5236754950`  
Dependency: Forge3D starter PR #82 + canonical Forge Runtime semantic automation PR #152

## Product state

- Product branch: `agent/v14-forge3d-semantic-self-play`
- Exact product head: `280c49fcbe93a0b1775daf1013246cef8b3ddfd0`
- Stacked base: `agent/forge-3d-kit-interactive-starter` / #82 exact starting head `ba8d820691201fa8653c8a0c5f09ed76644aacfe`
- Compare at checkpoint: 14 commits ahead, 0 behind; final delta remains exactly 4 files under `Packages/Forge3DKit/**`.
- No changes to ForgeRuntimeKit, WebKitHost, Mission, Completion, app shell, pbxproj, providers, Local AI, Forge2D, or global product docs.

## Implemented

1. Generated pause control opts into the canonical #152 bridge with `data-novaforge-control="scene.pause-toggle"`.
2. Generated assistive throttle/steering range inputs opt into `data-novaforge-action="drive.throttle"` / `drive.steer`.
3. The starter consumes the canonical `novaforge:action` event, validates action identity, clamps non-finite/out-of-range values into the bounded `[-1, 1]` contract, mirrors values to the native range input, and preserves the existing accessibility input path.
4. `Forge3DSemanticAutomationDescriptor` exposes deterministic pause/throttle/steer target IDs and action ranges for starter-owned discovery.
5. Target IDs, action ranges, and action-event name are single-sourced through `Forge3DSemanticContract` to reduce metadata/HTML/JS drift.
6. `.semanticAutomation` is a generated-artifact capability only; docs explicitly state it does not grant host/runtime authority or prove delivery.
7. Public `Forge3DGeneratedProject` construction is fail-closed: external-style construction cannot mint `.semanticAutomation` metadata/capability.
8. Package-owned construction revalidates the exact emitted HTML/JavaScript semantic bindings before advertising `.semanticAutomation`; missing or tampered bindings downgrade to no automation capability/descriptor.
9. Regression coverage verifies canonical markup/event names, deterministic target/range metadata, wrong-action rejection markers, clamping contract, public mint denial, missing-contract denial, and tampered-contract denial.

## Validation

Current exact-head validation branch: `validation/v14-forge3d-semantic-self-play-current`  
Validation child commit: `8c738f704d47880d4799a77973c06056426dda3e`  
Workflow run: `31364532891`

The validation workflow asserts its parent is exactly product head `280c49fcbe93a0b1775daf1013246cef8b3ddfd0`, asserts no `Packages/Forge3DKit` diff between product head and validation child, and runs package tests with warnings as errors.

- Ubuntu 24.04 / Swift 6.3.3 debug: PASS, 9 tests, 0 failures.
- Ubuntu 24.04 / Swift 6.3.3 release: PASS.
- macOS 14: QUEUED at checkpoint time; no macOS success claim.

Earlier targeted checks also passed for emitted JavaScript syntax, semantic action behavior, wrong-action rejection, value bounding, native range-input preservation, canonical #152 bridge compatibility for throttle/steer/pause, unknown-target fail-closed behavior, and descriptor/capability invariants.

A first validation-only run (`31363852153`) failed before Swift because the workflow used checkout depth 1 while asserting `HEAD^`; that harness defect was corrected with `fetch-depth: 2` and is not product failure evidence.

## Publication blocker

GitHub's secondary content-creation rate limit is currently rejecting pull-request creation and issue-comment checkpoint writes with HTTP 403. The most recent PR-create failure was at `2026-08-10T07:08:27Z`. There is therefore no PR number yet for `agent/v14-forge3d-semantic-self-play`.

When content creation is available again, create a **draft stacked PR**:

- base: `agent/forge-3d-kit-interactive-starter`
- head: `agent/v14-forge3d-semantic-self-play`
- title: `[V14] Make Forge3D starter discoverable by semantic self-play`

Then attach the exact-head validation evidence, refresh #82/#152 live state, and continue hosted macOS / WebKit / Simulator integration evidence as appropriate.

## Truth boundary

This checkpoint proves only generated-artifact structural discoverability/addressability plus package-level behavior/tests. It does **not** prove trusted WebKit delivery, authorized runtime execution, autonomous gameplay success, Completion acceptance, accessibility runtime acceptance, performance, iPhone Simulator behavior, or physical-device behavior. ForgeRuntimeKit remains authoritative for session authorization, source-revision binding, interaction budgets, dispatch, and trusted evidence.

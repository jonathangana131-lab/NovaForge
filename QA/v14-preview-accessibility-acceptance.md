# V14 Preview accessibility acceptance

Worker: `GPT56-SOL-NF-V14-PREVIEW-A11Y-0810`  
Protocol: `NF-SWARM-v14`  
Initial base: `main@991ece0ed9add9acf1108055f489b25f6cc9843f`

## Purpose

The pre-2.0 Preview Acceptance Constitution requires the normal agent harness to be usable at accessibility sizes and to avoid major clipping, overlap, unreadable controls, and inaccessible critical actions. Current `main` already contains useful deterministic UI journeys, but ordinary Critical CI exercises only part of that surface and the synchronized visual census is not run for every pull request.

Current `main` also contains the repaired theme-reset fixture and explicitly leaves fresh all-five Simulator visual acceptance as a later gate. This lane therefore produces all-five exact-source screenshot inputs while it runs the accessibility/readability checks, without taking ownership of theme implementation or claiming screenshot capture equals visual approval.

This lane adds a dedicated exact-head acceptance producer without modifying production presentation code or the shared `AgentPadUITests.swift` owner path.

The job is intentionally **not** another every-PR 45-minute Simulator tax. It auto-runs while this acceptance contract itself changes, then remains available through `workflow_dispatch` with an optional exact `source_sha` for release-candidate qualification. A dispatch that supplies anything other than a full 40-character commit SHA fails closed.

## Exact accessibility/readability journeys

The workflow runs these existing tests against one exact built source revision:

1. `testCanonicalActivityApprovalIsAccessibleCompactAndLegacyFree`
   - launches the canonical activity fixture at `UICTContentSizeCategoryAccessibilityXXXL`;
   - exercises the approval surface in White Gold;
   - checks critical controls remain reachable, non-overlapping, and large enough for touch;
   - rejects legacy duplicate approval presentation;
   - captures the expanded accessibility state.
2. `testAccessibilityLayoutTouchTargetsAndCompactLabels`
   - exercises the normal Forge surface with the deterministic provider-list fixture;
   - checks compact labels and touch-target/layout invariants used by the normal Preview harness.
3. `testGoalMatrixChatReadabilityAndThemeSwitchingScreenshots`
   - exercises representative Matrix Rain chat/readability state plus theme switching;
   - captures Matrix chat, Midnight settings after a real theme change, and the returned Midnight Forge surface;
   - contributes screenshot evidence for theme/readability interaction instead of treating source inspection as visual proof.

The workflow captures XCTest output and test screenshots under `artifacts/v14-preview-accessibility/` and uploads them even on failure. A successful XCTest log is **not sufficient** if the screenshot evidence channel is broken: the gate requires at least four PNGs from the selected journeys before it writes `xctest=PASS`.

## Five-theme exact-source screenshot inputs

After the focused XCTest journeys pass, the workflow reuses NovaForge's existing `scripts/codex-fast-screenshot.sh` helper against the exact `NovaForge.app` whose embedded source marker was already verified. It launches the same canonical activity/chat state once in each current Preview theme world:

- `matrixRain`
- `midnightBlack`
- `whiteGold`
- `arcticGlass`
- `emberCore`

Each launch uses `--reset-ui`, the explicit `--theme-world=<theme>` override, `--canonical-activity-a11y-demo`, and `--open-chat`. This deliberately exercises the repaired reset/override path in current `main` rather than relying on persisted state from a prior launch.

Each PNG must satisfy the existing screenshot helper's 120,000-byte readiness floor. The workflow requires exactly five theme PNGs, stores per-file byte counts and SHA-256 digests in `theme-manifest.txt`, and writes a separate `themeCapture=PASS` receipt only after all five are present.

**Important:** this is an evidence producer, not an automatic aesthetic judge. Five successfully captured PNGs prove that exact-source evidence exists for all five requested theme launches; they do not prove the themes are beautiful, sufficiently distinct, unclipped on every surface, or visually accepted. Human/screenshot critique remains required before final Preview visual acceptance.

## Fail-closed identity checks

Before XCTest or theme capture is allowed to count as evidence, the workflow requires:

- a full 40-character source commit SHA;
- checkout SHA exactly equals the PR head, dispatched `source_sha`, or dispatched workflow SHA;
- the configured Simulator UDID exists and identifies an available **iPhone 12**;
- that Simulator belongs to an **iOS 27** runtime;
- the built `NovaForge.app` contains `NovaForgeSourceCommit` exactly matching the tested source SHA;
- all three focused XCTest journeys succeed;
- at least four accessibility/readability screenshots are actually emitted;
- the same exact-source app emits exactly five ready theme-world PNGs.

A mutable branch name, stale app, wrong simulator class/runtime, missing source marker, missing test bundle, XCTest failure, missing visual artifacts, or incomplete five-theme capture makes the workflow red.

## Truth boundary

A green run is **Simulator accessibility/layout/readability evidence for the three named journeys plus exact-source screenshot inputs for all five Preview theme worlds**. It does not by itself prove:

- physical iPhone 12 accessibility behavior;
- a full VoiceOver rotor/focus traversal of every Preview screen;
- Reduce Motion or Reduce Transparency runtime acceptance;
- final human visual acceptance of all five themes or every major/weak/loading/error/offline surface;
- Local AI model qualification, hosted provider health, network isolation, RAM/thermal/energy behavior, or long-session performance;
- final Preview release readiness.

Source inspection confirms current Composer motion uses `accessibilityReduceMotion`, and shared glass/background rendering has `accessibilityReduceTransparency` fallbacks, but those code paths are **not** promoted to runtime acceptance by this workflow because the selected journeys do not deliberately toggle those system settings.

Those remain separate acceptance gates. In particular, the existing short performance trace still must not be promoted to long-session proof.

## Collision boundary

This slice changes only:

- `.github/workflows/v14-preview-accessibility-acceptance.yml`;
- this QA receipt/contract.

It intentionally does not touch `AgentPad/**`, `AgentPadUITests/AgentPadUITests.swift`, `AgentPad.xcodeproj/project.pbxproj`, provider routes, Local Model runtime/catalog, Forge Compact, theme implementation, session persistence, `ci/verify.sh`, or Full Forge/Completion authority.

# V14 Preview accessibility acceptance

Worker: `GPT56-SOL-NF-V14-PREVIEW-A11Y-0810`  
Protocol: `NF-SWARM-v14`  
Initial base: `main@991ece0ed9add9acf1108055f489b25f6cc9843f`

## Purpose

The pre-2.0 Preview Acceptance Constitution requires the normal agent harness to be usable at accessibility sizes and to avoid major clipping, overlap, unreadable controls, and inaccessible critical actions. Current `main` already contains useful deterministic UI journeys, but ordinary Critical CI exercises only part of that surface and the synchronized visual census is not run for every pull request.

This lane adds a dedicated exact-head acceptance producer without modifying production presentation code or the shared `AgentPadUITests.swift` owner path.

## Exact journeys

The workflow runs these existing tests against one exact built source revision:

1. `testCanonicalActivityApprovalIsAccessibleCompactAndLegacyFree`
   - launches the canonical activity fixture at `UICTContentSizeCategoryAccessibilityXXXL`;
   - exercises the approval surface in White Gold;
   - checks critical controls remain reachable, non-overlapping, and large enough for touch;
   - rejects legacy duplicate approval presentation.
2. `testAccessibilityLayoutTouchTargetsAndCompactLabels`
   - exercises the normal Forge surface with the deterministic provider-list fixture;
   - checks compact labels and touch-target/layout invariants used by the normal Preview harness.
3. `testGoalMatrixChatReadabilityAndThemeSwitchingScreenshots`
   - exercises representative Matrix Rain chat/readability state plus theme switching;
   - contributes screenshot evidence for theme/readability interaction instead of treating source inspection as visual proof.

The workflow captures XCTest output and test screenshots under `artifacts/v14-preview-accessibility/` and uploads them even on failure.

## Fail-closed identity checks

Before XCTest is allowed to count as evidence, the workflow requires:

- checkout SHA exactly equals the PR head (or dispatched SHA);
- the configured Simulator UDID exists and identifies an available **iPhone 12**;
- that Simulator belongs to an **iOS 27** runtime;
- the built `NovaForge.app` contains `NovaForgeSourceCommit` exactly matching the tested source SHA;
- all three focused XCTest journeys succeed.

A stale app, wrong simulator class/runtime, missing source marker, missing test bundle, or XCTest failure makes the workflow red.

## Truth boundary

A green run is **Simulator accessibility/layout/readability evidence for these three journeys only**. It does not by itself prove:

- physical iPhone 12 accessibility behavior;
- a full VoiceOver rotor/focus traversal of every Preview screen;
- Reduce Motion or Reduce Transparency runtime acceptance;
- every one of the five themes or every weak/loading/error/offline state;
- Local AI model qualification, hosted provider health, network isolation, RAM/thermal/energy behavior, or long-session performance;
- final Preview release readiness.

Those remain separate acceptance gates. In particular, the existing short performance trace still must not be promoted to long-session proof.

## Collision boundary

This slice changes only:

- `.github/workflows/v14-preview-accessibility-acceptance.yml`;
- this QA receipt/contract.

It intentionally does not touch `AgentPad/**`, `AgentPadUITests/AgentPadUITests.swift`, `AgentPad.xcodeproj/project.pbxproj`, provider routes, Local Model runtime/catalog, Forge Compact, theme implementation, session persistence, `ci/verify.sh`, or Full Forge/Completion authority.

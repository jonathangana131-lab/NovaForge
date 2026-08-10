# V14 Preview Five-Theme Contract Receipt

Protocol: NF-SWARM-v14  
Worker: GPT56-SOL-NF-V14-PREVIEW-THEMES-0810  
Recomposed base: `main@ee9acb7a3d289465b48ce2427a5cba906390e581`  
Branch: `agent/v14-preview-five-theme-contract-e2`

## Preview contract covered

The Preview must keep exactly these normal theme worlds available as one coherent Settings surface:

1. Matrix Rain
2. Midnight Black
3. White Gold
4. Arctic Glass
5. Ember Core

The contract guard verifies the canonical enum still contains exactly those five cases, that the five public titles remain bound to them, and that White Gold remains the light world while the others remain dark.

## Persistence / wiring evidence

Source inspection on the recomposed exact base confirms:

- `AgentTheme.storageKey` is the single stored theme key and Midnight Black is the default.
- stored values are normalized through `AgentTheme.normalizeStoredTheme()` and legacy aliases resolve through the canonical theme matcher.
- app launch accepts explicit theme-world overrides, stores the selected raw value, refreshes the palette cache, reapplies UIKit appearance, and applies the selected preferred color scheme at the root scene.
- Control / Settings enumerates `AgentTheme.allCases`, persists the tapped raw value through `@AppStorage`, refreshes `AgentPalette`, reapplies `AgentThemeUIKit`, and exposes stable accessibility identities for the theme studio cards.
- the existing UI journey `testGoalMatrixChatReadabilityAndThemeSwitchingScreenshots` already interacts with Matrix Rain and Midnight Black and captures visual proof hooks after selection.

## New durable regression

Added:

- `scripts/verify_v14_preview_theme_contract.sh`
- `.github/workflows/v14-preview-theme-contract.yml`

The guard fails if the canonical five-world set changes, public titles disappear, storage/default/normalization wiring is removed, Settings stops enumerating all cases or persisting/applying selections, root launch/relaunch wiring disappears, stable theme-card accessibility identity is removed, or the existing Matrix/Midnight interactive proof hook is deleted.

## Convergence

The first draft branch was cut at `9499a5c3bd3d5bd9e6d5a7c0cd11f08575bf1a8b`. While the lane was being prepared, main advanced through unrelated Preview effort presentation work. This e2 branch was therefore recomposed from live `main@ee9acb7a3d289465b48ce2427a5cba906390e581` rather than merging stale history. The lane remains additive guard/evidence only.

## Review finding kept explicit

The DEBUG/Simulator `--reset-ui` fixture resets the stored theme and then refreshes the palette cache from `AgentTheme.current`. Because `current` is intentionally cached, this deserves a focused macOS/Simulator follow-up to prove reset launches cannot momentarily retain a prior cached world when no explicit `--theme-world` override is present. This receipt does **not** promote that inference into a production-user defect claim; normal user theme selection and cold-launch normalization use different paths.

## Truth boundary

This worker does not have the macOS/iOS Simulator runtime required for fresh iPhone 12 / iOS 27 visual interaction evidence. The new guard is deterministic source-contract evidence, not visual acceptance. Existing repository UI coverage proves interactive Matrix -> Midnight switching hooks exist, but this worker does not claim all five worlds have fresh exact-head screenshots, accessibility acceptance, or physical-device proof. Those remain part of the release-candidate visual/theme sweep.

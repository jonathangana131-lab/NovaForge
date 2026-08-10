# V14 Preview Theme Reset Cache Determinism Receipt

Protocol: NF-SWARM-v14  
Worker: GPT56-SOL-NF-V14-PREVIEW-THEME-RESET-0810  
Base: `main@37b5305c459907917d1f27ddc7f08168a68c4bbe`  
Branch: `agent/v14-preview-theme-reset-cache`

## Defect

The DEBUG/Simulator `--reset-ui` launch fixture first resets stored theme state to the canonical default and then reapplies an explicit `--theme-world` override when present. The previous code then refreshed `AgentPalette` from `AgentTheme.current`.

`AgentTheme.current` is intentionally cached for hot SwiftUI body paths. During the same app initialization, that cache can already contain the theme resolved before `--reset-ui` rewrites `UserDefaults`. The reset fixture could therefore have persisted one theme while reapplying a previously cached theme to the live palette/UIKit appearance for that launch.

This is a Simulator/debug-fixture determinism defect. It is not promoted into a normal production-user theme persistence defect claim.

## Repair

In the reset path only:

`AgentPalette.refreshThemeCache(AgentTheme.current)`

becomes:

`AgentPalette.refreshThemeCache(AgentTheme.normalizeStoredTheme())`

The order is now explicit:

1. reset theme storage to `AgentTheme.defaultTheme`;
2. apply an explicit launch override when supplied;
3. re-resolve/normalize the just-written stored theme;
4. refresh the hot palette/current cache from that canonical value;
5. reapply UIKit appearance from the refreshed `AgentTheme.current`.

No theme palette values, public theme names, production selection behavior, provider/session state, or visual styling are changed.

## Exact mutation evidence

A branch-only one-shot workflow performed the edit because the GitHub contents API requires full-file replacement for the very large `AgentPadApp.swift`. The one-shot workflow:

- required one exact reset sequence before editing;
- replaced only that sequence;
- ran `git diff --check`;
- committed the repair;
- removed itself in the same commit.

GitHub compare after that commit showed exactly one production file changed with `+1/-1`: `AgentPad/App/AgentPadApp.swift`. The temporary workflow has no net branch diff.

## Durable regression

Added:

- `scripts/verify_v14_preview_theme_reset_cache.sh`
- `.github/workflows/v14-preview-theme-reset-cache.yml`

The guard isolates the `--reset-ui` block and fails if:

- canonical default/override storage writes disappear;
- the reset path stops normalizing stored theme before palette refresh;
- the stale cached-current refresh returns;
- UIKit is not applied after cache refresh;
- the canonical theme normalizer/cache-refresh authority disappears.

## Truth boundary

The deterministic source defect and one-line repair are proven by exact GitHub compare and the dedicated contract. This worker does not claim an iOS 27 Simulator screenshot comparison, all-five visual acceptance, physical-device evidence, or production performance impact. The repaired fixture should be used by the release-candidate theme screenshot/a11y sweep so its visual evidence cannot be poisoned by stale cached theme state.

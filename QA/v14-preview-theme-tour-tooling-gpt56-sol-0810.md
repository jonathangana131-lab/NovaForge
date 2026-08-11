# V14 Preview Five-Theme Release-Candidate Tour Tooling

Protocol: NF-SWARM-v14  
Worker: GPT56-SOL-NF-V14-PREVIEW-THEME-TOUR-0810  
Base: `main@991ece0ed9add9acf1108055f489b25f6cc9843f`  
Branch: `agent/preview-theme-tour`

## Why this lane exists

The Preview Acceptance Constitution requires all five NovaForge theme worlds to persist and pass a release-candidate screenshot/readability review. Current `scripts/codex-sim-tour.sh` has one themed sample per world, but each world is shown on a different surface. That can miss a theme-specific defect that appears only in Forge, approval, Local Model Center, missing-local-model, or History states.

This lane does not change theme styling or persistence. It adds the repeatable evidence path needed for the later exact-head visual acceptance pass.

## New matrix

`scripts/codex-preview-theme-tour.sh` captures exactly 25 frames: five canonical themes multiplied by five Preview-critical states.

Themes:

- Matrix Rain (`matrixRain`)
- Midnight Black (`midnightBlack`)
- White Gold (`whiteGold`)
- Arctic Glass (`arcticGlass`)
- Ember Core (`emberCore`)

States per theme:

1. clean Forge/chat;
2. pending approval;
3. Control with Local Model ready fixture;
4. Local model missing weak state;
5. History proof state.

The tour builds once, reuses the installed app, uses the repaired `--reset-ui` + `--theme-world` fixture on every frame, records the exact source SHA and simulator/configuration in a manifest, and shuts the Simulator down after the matrix.

## Fail-closed verification

`scripts/codex-preview-theme-tour-verify.sh` requires:

- exact 40-character source SHA in the manifest;
- all 25 expected frame names and no extra PNGs;
- minimum image byte size and readable pixel dimensions;
- unique hashes across the capture matrix so a stuck launch/state cannot quietly duplicate a previous frame;
- lightweight semantic screen checks using the same macOS Vision pattern as the existing general tour verifier.

`scripts/verify_v14_preview_theme_tour_contract.sh` is Linux-runnable and locks the canonical five AgentTheme cases, five matrix states, exact launch-argument forwarding, repaired reset fixture, exact 25-frame manifest contract, and explicit non-acceptance wording.

## What this proves

It proves that the repository has one deterministic command for generating a much stronger all-five-theme release-candidate evidence set and that incomplete/stuck/misrouted captures fail verification instead of looking green by file count alone.

## What this does not prove

No iOS 27 Simulator run is claimed by this branch yet. No screenshot has been visually accepted. No physical iPhone 12 evidence, contrast measurement, VoiceOver acceptance, Dynamic Type acceptance, performance/frame-pacing result, or production theme correctness is inferred from static tooling. A release worker with macOS/iOS 27 Simulator access must run the matrix on the exact candidate SHA and critique the resulting frames before checking the Preview theme acceptance box.

# NF-SWARM-v14 claim — Plan Space current-main recovery

Worker: `GPT56-NF-V14-PLANUI-8A8L`  
Claimed base: `main@5cd5a75849fde2a0d16d5c915433364e7d8e8a60`  
Canonical domain dependency: merged PR #49 (`Packages/ForgePlanCore`)  
Stale presentation source: draft PR #76

## Lane

Recover the existing canonical Plan Space / Composer presentation slice from stale stacked PR #76 onto current V14 main without redesigning the flagship blindly.

## Ownership boundary

Expected presentation scope only:
- Xcode linkage needed for already-merged `ForgePlanCore`;
- `AgentPad/Views/ChatHeaderStrip.swift` Plan Space surface;
- `AgentPad/Views/ChatView.swift` current unsent draft handoff;
- focused existing `AgentPadUITests` journey if it still composes cleanly.

Avoid `scripts/codex-test.sh` unless a fresh contention check proves it is necessary and safe; current V14 package-gate/recovery work is already active. No Mission/Project Brain, Forge Runtime, Local AI, provider, Forge Compact, Home/My Apps, or Voltline mutation.

## Recovery rule

Recompose against live files and preserve only semantics that remain compatible with current main. Do not restore an old SHA wholesale. No Xcode/Simulator/visual acceptance claim without exact current-head evidence.

# NovaForge V14 — Forge Compact Provider Wiring Audit

Date: 2026-08-10
Worker: `GPT56-SOL-NF-V14-FORGECOMPACT-INTEGRATION-8A10`
Base audited: `37b5305c459907917d1f27ddc7f08168a68c4bbe`

## Verdict

**Forge Compact is not yet integrated into the app's canonical provider-context path on the audited base.**

The repository contains `Packages/ForgeCompactCore` and its deterministic `ProjectCapsuleBuilder`, but package existence is not app integration. The audited `AgentPad.xcodeproj/project.pbxproj` does not link `ForgeCompactCore`, and `AgentPad/Services/AgentCanonicalContextPreparer.swift` does not import or invoke the capsule builder.

Do not count Forge Compact as `IN APP / INTEGRATED` until the structural gate added in this branch passes and the normal build/test lane is green.

## Safe integration boundary

The first app integration should compact only the existing artifact/checkpoint project-memory supplement. It must not rewrite, summarize, reorder, or omit `state.modelItems`, canonical tool-call envelopes, tool results, or the independently supplied tool definitions.

That boundary preserves the agent runtime's canonical transcript/tool semantics while giving Forge Compact a real provider-bound memory lane.

## Required closure

1. Link local package `Packages/ForgeCompactCore` and product `ForgeCompactCore` into the AgentPad app target.
2. Import `ForgeCompactCore` in `AgentCanonicalContextPreparer.swift`.
3. Adapt the existing artifact/checkpoint supplement into deterministic `ForgeCompactContextItem` values with provenance and a source revision bound to the canonical state.
4. Build a `ProjectCapsule` with an explicit provider-context byte budget.
5. Feed `ProjectCapsule.renderedContext` into the existing developer supplement path.
6. Preserve canonical `state.modelItems` and tool definitions without compaction.
7. Fail closed if required retained truth cannot fit the chosen budget; never silently drop required truth.
8. Add focused tests for deterministic ordering, bounded output, retained required truth, empty-memory behavior, and canonical transcript/tool preservation.
9. Run the normal macOS build/test lane and iPhone 12 Simulator regression suite appropriate to the touched path.
10. Measure physical iPhone 12 RAM/context/latency effects separately before making performance claims.

## Machine-readable gate

Run from repository root:

```sh
python3 scripts/verify-forge-compact-provider-wiring.py
```

A pass proves only structural wiring. It does **not** prove RAM savings, speed, thermal behavior, energy improvements, local-model compatibility, or quality preservation. Those require measured evidence on the exact runtime/device configuration.

## Current audited gate expectation

On the audited base the expected structural results are:

- `ForgeCompactCore product`: PASS
- `app target package link`: FAIL
- `canonical preparer import`: FAIL
- `capsule construction`: FAIL
- `provider-bound capsule consumption`: FAIL
- `canonical transcript/tool path preserved`: PASS

This report is deliberately conservative: Preview progress should reflect product reality rather than package/PR count.

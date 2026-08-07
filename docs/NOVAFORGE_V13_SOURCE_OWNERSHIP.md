# NovaForge V13 source-of-truth ownership

Status: stacked architecture checkpoint for issue #42  
Protocol: NF-SWARM-v13  
Source inspected: `df1740f12f5e0b26780868c1cd906ee8cae497ae`  
Depends on migration contract checkpoint: PR #47 / `b6309e38e41e5cd06c8b37a12905cae625a4329d`

This map turns the V13 controlled rewrite into an ownership change rather than a giant source move. It is intentionally additive: no live app, provider, runtime, policy, or UI source is changed by this checkpoint.

Machine-readable authority: `docs/architecture/novaforge-v13-source-ownership-map.json`  
Validator: `scripts/validate_v13_source_ownership.py`

## Principle: preserve truth, replace gravity wells

File size is evidence of coordination pressure, not evidence that code is bad. The rewrite rule is based on responsibility:

- **Preserve** code that already owns durable/security/provider/tool truth well.
- **Preserve then extract** proven behavior that belongs in a clearer V13 module.
- **Decompose behind an adapter** mixed runtime/composition owners so new code does not inherit their accidental coupling.
- **Replace behind a seam** legacy user surfaces whose information architecture conflicts with V13.
- **Mine then replace** optional/presentation code that contains useful interaction work but must not define the next design system.

At the pinned source head, the pressure is measurable: `AppRootView.swift` is 257,784 bytes, `AgentRuntime.swift` is 195,441 bytes, `ChatView.swift` is 139,667 bytes, and `ArtifactPreviewSheet.swift` is 120,134 bytes. Those files also mix responsibilities that V13 assigns to separate long-lived owners.

## What survives inward

`Packages/AgentHarnessKit` already separates reusable foundations into `AgentDomain`, `AgentEngine`, `AgentPolicy`, `AgentProviders`, `AgentReducerCore`, `AgentShadow`, `AgentStore`, `AgentTools`, and `AgentTransport`.

That package is the preferred inward dependency for the generational rewrite. New V13 product modules should call proven contracts or explicit typed adapters instead of importing old views.

Other protected foundations include:

- hosted provider transport/gateway/router behavior -> `ProviderRuntime`;
- local SwiftLlama/llama.cpp behavior -> `ModelRuntime`, with catalog metadata separated into `ModelCatalog`;
- provider Keychain credentials -> preserve in place;
- approval-signing authority -> preserve in its separate Data Protection Keychain boundary;
- engine run ownership -> `ForgeMission` / `ProjectHistory` / `ProjectStore`;
- policy/checkpoint storage -> `AgentPolicy` / `ProjectStore`;
- legacy launch migration/recovery -> `ProjectStore` before app composition is simplified.

This is why the V13 rewrite is not “delete legacy and start clean.” The shell can be new while durable and security truth remains continuous.

## Mixed owners that must be decomposed

### `AgentRuntime.swift`

`AgentRuntime` is a 195 KB transitional owner spanning chat/run observation state, provider dispatch, tool-loop bridging, persistence projections, and UI-facing status. Its own code still documents a legacy scalar-string `FlatToolArgumentParser` bridge.

V13 rule: do not make this class the Mission Engine database. It can remain behind an adapter while responsibility moves to:

- `ForgeMission` for durable mission lifecycle;
- `ProviderRuntime` for routes/inference transport;
- `AgentTools` for typed tools;
- `ProjectStore` for persistence.

The scalar-string bridge is explicitly prohibited from becoming the V13 tool contract, and the chat transcript is explicitly prohibited from becoming durable mission identity.

### `AgentPadApp.swift`

The app entry point currently carries both composition and proven persistence migration/recovery behavior. Those are different responsibilities. `ProjectStore` must absorb the migration/reconciliation truth before `AppShell` becomes a thin composition root.

## Presentation gravity wells

The ownership map pins the major replacement surfaces and their observed sizes:

| Legacy surface | Pinned size | V13 destination |
| --- | ---: | --- |
| `AppRootView.swift` | 257,784 B | AppShell + projects + mission + history |
| Chat surface (`ChatView`, composer/messages/progress) | 320,883 B combined | ForgeMission + DesignSystem |
| `ArtifactPreviewSheet.swift` | 120,134 B | ForgeRuntime + RuntimeBridge + VisualQA |
| Files surface | 198,223 B combined | ProjectStore + ProjectBrain + Edit/Inspect presentation |
| Project Dashboard family | 259,522 B combined | ForgeProjects + ProjectHistory |
| Runs/RunCards | 163,448 B combined | ProjectHistory |
| Settings/model panels | 145,386 B combined | Model Center / Control owners |
| `TerminalConsoleView.swift` | 66,997 B | optional expert surface, not core architecture |
| `GlassControls.swift` | 52,298 B | mine useful behavior, then replace with V13 DesignSystem |

These are **replacement surfaces**, not immediate deletion targets. Each has an explicit acceptance gate in the JSON contract.

## Staged replacement seams

1. **Truth contracts** — migration contract + ownership map become accepted rewrite guards.
2. **ProjectStore facade** — one owner wraps current SwiftData/workspace/compatibility/recovery truth without prematurely changing authoritative bytes.
3. **AppShell composition** — V13 surfaces can enter through a thin shell while the legacy root remains a controlled rollback route.
4. **Mission adapter** — missions execute/resume through durable harness/receipt state, not transcript identity.
5. **Forge Runtime host** — runnable project hosting moves from artifact-sheet presentation to the sandboxed full-screen product runtime.
6. **Feature projection cutover** — My Apps, History, Control/Model Center move only after parity plus visual/accessibility/performance evidence.
7. **Legacy retirement** — old owners are deleted only after exact-head replacement and migration gates pass.

This is a strangler-style rewrite: each seam is reversible until the replacement has evidence.

## Dependency law

The validator enforces the architecture laws that matter most:

- New V13 modules may depend on AgentHarnessKit or typed adapters; they must not import `AgentPad/Views` as source-of-truth dependencies.
- `AppShell` owns composition, not provider/tool/policy/persistence/mission business logic.
- `ProjectStore` owns project/workspace persistence and migration/reconciliation.
- `ForgeMission` identity is independent of transcript and legacy observation state.
- `AgentPolicy` remains the authority boundary; UI/model output cannot mint capability.
- `RuntimeBridge` is explicit and versioned; Forge projects cannot reach secrets or arbitrary native authority.
- `ProjectHistory` projects evidence and does not execute work.
- `DesignSystem` has no feature/domain dependencies.
- Cloud/Mac modules are not ordinary dependencies until real execution substrates exist.

## Existing migration proof to reuse

The repo already has real migration coverage, including a captured pre-explicit V1 store fixture under `AgentPadTests/Fixtures/NovaForgePreExplicitV1`. That fixture contains frozen source bytes, checksums, entity signature, and semantic digest.

The next #42 test seam should extend that existing fixture culture across V13 ownership boundaries rather than inventing a parallel migration framework: SwiftData + run ownership + policy/checkpoint state + workspace identity + relaunch comparison.

## Validation

```sh
python3 scripts/validate_v13_source_ownership.py --self-test --repo-root .
```

The validator checks required V13 owners, required preserved foundations/hotspots/adapters, exact source/head pinning, valid destination ownership, prohibited promotion of legacy views, `AgentRuntime` decomposition, ordered replacement seams, substantive deletion gates, source existence, and pinned byte sizes for the measured hotspots.

## Non-goals of this checkpoint

- No new V13 UI is wired here; #35/#39 remain free to evolve their surfaces.
- No provider route or policy behavior changes.
- No migration deletes or relocates user data.
- No fake `CloudContinuation` or `MacWorker` module is introduced.
- No claim that a large file is automatically wrong.
- No claim that this ownership document by itself satisfies #42's future running-app migration seam.

The checkpoint exists so those implementation PRs can move aggressively without losing track of which old behavior is truth, which is compatibility, and which is presentation debt.

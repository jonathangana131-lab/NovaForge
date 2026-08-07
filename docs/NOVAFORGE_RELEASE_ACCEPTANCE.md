# NOVAFORGE RELEASE ACCEPTANCE
Snapshot: 2026-08-06

## Principle
Exact-head evidence only. A green build, screenshot, or device run on a different commit is not release evidence for the candidate.

## Gate 0 — Source hygiene
- candidate descends from intended main;
- no Voltline/foreign files;
- no unresolved conflict markers;
- no accidental secrets/binaries;
- durable docs current for architectural changes.

## Gate 1 — Build
- clean build with supported Xcode/iOS SDK;
- dependency resolution succeeds;
- warnings reviewed;
- bundle launches.

## Gate 2 — Package/unit/contract tests
Cover AgentDomain/Engine/Policy/Store, provider adapters/dialects, provider error mapping, acceptance-before-dispatch, mutation boundaries, persistence recovery/migration, context preparation, local-model lifecycle, stream handoff and cancellation.

## Gate 3 — Critical provider journeys
For every ordinary SUPPORTED route:
- setup/model selection;
- fresh send;
- streaming;
- cancel/retry;
- app relaunch;
- actionable 401/402/403/404/408/413/422/429/5xx, with 413 classified as context-limit rather than generic invalid request;
- exact route/model receipt.

At least one supported hosted route must pass end-to-end before release.

## Gate 4 — Agent/tool journeys
- read-only tool;
- mutation requiring approval;
- deny path;
- accepted write;
- verify changed file;
- command-risk path;
- provider failure after tool;
- recovery without duplicate mutation.

## Gate 5 — Persistence/recovery
Test interruption during stream/approval, partial provider response, failed command, stale provider setting, local partial download, migrations, and duplicate/canonical record selection.

## Gate 6 — Security
- no dispatch before accepted run;
- no accepted-run durable events before acceptance;
- approval identity/replay checks;
- path traversal blocked;
- workspace identity exact;
- Keychain secrets absent from logs/receipts;
- local-only has no hosted fallback;
- repository/prompt-injection content cannot mint tool authority.

## Gate 7 — Simulator UI journeys
Canonical tour covers Forge empty/active/streaming/approval/error, composer+keyboard, project scope/dossier, Workspace files/diff/artifacts/terminal, History receipt, Control provider/model/local lifecycle, light/dark, and accessibility variants.

Screenshot proof comes from exact candidate SHA or a documented equivalent build artifact.

## Gate 8 — Visual review
Review hierarchy, clipping, wasted top space, card/pill duplication, keyboard avoidance, long content, empty/error/loading, theme contrast, glass overuse, and native sheet/menu behavior. No “looks good” acceptance without notes.

## Gate 9 — Accessibility
VoiceOver traversal, large Dynamic Type, touch targets, Reduce Motion, Reduce Transparency, Increase Contrast, and no color-only status.

## Gate 10 — Performance
Baseline target is iPhone 12/A14 unless constitution changes. Check launch, tab switch, long chat scroll, active streaming, tool timeline, large file preview, run history, memory growth, and local-model isolation. Use ETTrace/Instruments/memgraph when risk or regression warrants it.

## Gate 11 — Physical iPhone
Required for local llama.cpp/Metal/memory/thermal claims, haptics, real keyboard feel, device-specific filesystem/security-scoped behavior, battery impact, and background lifecycle where used.

Record device, OS, model file, context, latency/tokens-per-second where measurable, memory/thermal observation, and exact app SHA.

## Gate 12 — Release receipt
Record SHA, CI run, tests, screenshots, device acceptance, known limitations, provider matrix, migrations, and rollback plan.

## Stop-ship conditions
- normal supported provider known unable to send;
- retry/recovery can duplicate mutation;
- unaccepted run can dispatch/mutate;
- secret leakage;
- local-only silently hits network;
- destructive action bypasses approval;
- migration loses user project/history;
- persistent crash/freeze in a primary surface;
- critical exact-head CI is red without a specifically reviewed infrastructure-only exception.

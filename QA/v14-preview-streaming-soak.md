# V14 Preview — Streaming Soak Evidence

**Protocol:** NF-SWARM-v14  
**Flagship:** pre-2.0 Preview  
**Producer:** `.github/workflows/v14-preview-streaming-soak.yml`

## Why this exists

The Preview Acceptance Constitution requires repeated-turn memory/context behavior to avoid uncontrolled growth and asks for long-session performance closure before release. The existing UI journey `testProjectLiquidGlassPerformanceTraceFlow()` is useful short-window frame/event instrumentation, but its Mission Dossier phase and stress-streaming phase are each only about eight seconds. That is not representative long-session proof.

This producer adds one narrow, non-conflicting evidence rung without modifying the shared UI-test or production-runtime files.

## What it proves when green

For one exact NovaForge source SHA on the configured iPhone 12 / iOS 27 Simulator, the workflow:

1. captures a durable runner preflight receipt before checkout or Simulator qualification, including macOS identity, selected Xcode, installed Xcode candidates, and the selected Simulator runtime/device inventory;
2. verifies the exact checked-out SHA and exact Simulator identity;
3. builds `NovaForge.app` with its `NovaForgeSourceCommit` marker and rejects a mismatched app;
4. installs and launches the existing deterministic `--stress-streaming` fixture as one process;
5. keeps that process alive for a 180-second soak;
6. samples host-observed process RSS and CPU every 15 seconds;
7. discards the first 45 seconds from memory-growth evaluation as warmup;
8. fails if the process exits or if conservative post-warmup RSS regression guardrails are exceeded;
9. captures start, midpoint, and end screenshots plus stdout/stderr, launch, build, policy, preflight, and sample receipts.

Current Simulator guardrails are deliberately conservative regression tripwires:

- final post-warmup RSS growth <= 128 MiB;
- least-squares post-warmup RSS slope <= 768 KiB/s;
- post-warmup RSS span <= 192 MiB.

These are engineering guardrails, **not** iPhone 12 memory budgets or device qualification thresholds.

## Failed preflight is evidence, too

A missing iOS 27 runtime, missing exact Simulator, incompatible Xcode selection, or other qualification failure must not vanish into an Actions log. The workflow writes `runner-preflight.txt` before those checks and treats an empty artifact set as an error. Therefore a red run can still leave a durable receipt explaining the hosted-runner boundary without being mislabeled as product failure or product success.

## What it does not prove

A green run does **not** close the Preview long-session rung by itself. It does not exercise a representative sequence of repeated chat turns, tool calls, History, theme changes, approvals, model switching, relaunch, or Local AI inference.

It also does not prove:

- physical iPhone 12 memory usage;
- iPhone thermal or energy behavior;
- Local model qualification;
- provider health;
- Forge Compact memory savings;
- absence of every leak;
- full frame-pacing acceptance;
- final Preview readiness.

The remaining long-session closer should compose this soak signal with a representative interaction workload and physical-device evidence where the Preview constitution requires it.

## Evidence integrity

The workflow accepts only a full 40-character source commit SHA, checks out that exact revision, verifies the built app embeds the same source marker, and uploads the raw CSV/log/screenshot evidence even on failure. The preflight receipt exists before checkout/qualification so infrastructure blockers remain durable rather than chat-only or log-only findings.

Automatic execution is path-bounded to this evidence contract. Later release-candidate qualification should use `workflow_dispatch` with an exact source SHA so an evidence receipt cannot silently follow a moving branch.

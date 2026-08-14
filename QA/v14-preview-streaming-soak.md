# V14 Preview finite-stream-triggered residency signal

Status: Preview evidence rung only. This document deliberately does **not** claim sustained streaming, representative long-session acceptance, or physical iPhone qualification.

> Filename note: this legacy `streaming-soak` path is retained for review continuity with superseded draft #263. The evidence class defined here is residency, not sustained streaming.

## Why this exists

NovaForge Preview needs durable evidence about process survival and gross memory-regression behavior beyond the short existing UI performance traces. The existing `--stress-streaming` launch fixture is finite: current source completes its programmed producer delay in roughly tens of seconds, not the full 180-second observation window.

Therefore this producer does **not** call the 180-second window a streaming soak. It invokes the existing finite streaming stress once, keeps the same NovaForge Simulator process alive, and measures a post-warmup residency signal. No accepted RSS sample is represented as proof that streaming is still active.

## Exact evidence scope

A green focused workflow run proves only that, for one exact source commit:

1. the configured available Simulator was bound to the canonical CoreSimulator iPhone 12 device type and an iOS 27 runtime identifier;
2. the NovaForge app container was absent before the exact-source app was installed, so prior NovaForge app data was not reused;
3. the built `NovaForge.app` embedded the exact requested source commit marker;
4. one `--stress-streaming` invocation launched in that exact app;
5. the same Simulator process survived the full 180-second observation window;
6. host-observed post-45-second RSS stayed inside conservative regression tripwires;
7. early/mid/end Simulator screenshots were nontrivial files; and
8. preflight, identity, source, app-container, sampling, logs, screenshots, and verdict receipts were durably uploaded even when later steps failed.

The workflow writes `streamingLivenessVerified=false`, `representativeLongSessionVerified=false`, and `physicalDeviceVerified=false` into its policy/verdict receipts so downstream readers cannot silently upgrade the evidence class.

## Simulator identity boundary

The configured UDID alone is not accepted as iPhone 12 evidence, and display name alone is not accepted because Simulator devices can be renamed.

The workflow requires:

- `deviceTypeIdentifier=com.apple.CoreSimulator.SimDeviceType.iPhone-12`
- runtime identifier beginning `com.apple.CoreSimulator.SimRuntime.iOS-27-`
- the configured Simulator to be available.

The exact UDID, display name, canonical device type identifier, runtime identifier, and pre-qualification state are persisted in `simulator-identity.txt`.

## Fresh app-container boundary

A Simulator reboot is not treated as a clean app-state proof. After boot, the producer checks whether `com.joey.NovaForge` already has a data container. If present, it uninstalls the app, then fails closed if the container is still discoverable. The receipt records whether an old installation existed and requires `appPresentAfterBoundary=false` before build/install/run.

This is a fresh **NovaForge app-container** boundary. It is not a claim that the entire Simulator was erased or that all system caches were reset; the receipt explicitly records `simulatorErased=false`.

## Source binding

The requested source must be an exact 40-character commit SHA. After checkout, `git rev-parse HEAD` must match it exactly. The build receives `NOVAFORGE_SOURCE_COMMIT=<sha>`, and the produced app's `NovaForgeSourceCommit` Info.plist value must match before install.

This prevents a workflow run from producing evidence for a different source tree than the one named by its receipt.

## Residency guardrails

The process is sampled every 15 seconds for 180 seconds. Guardrail calculations exclude the first 45 seconds as warmup and require at least six accepted samples.

Conservative Simulator/host-RSS regression tripwires:

- final positive RSS growth from the first accepted sample: <= 128 MiB;
- least-squares RSS slope across accepted samples: <= 768 KiB/s;
- accepted-window RSS span: <= 192 MiB.

These thresholds are intentionally coarse tripwires. They are **not** device memory budgets, iPhone 12 qualification thresholds, Forge Compact savings targets, or product SLOs.

The accepted window is labeled residency, not streaming. A PASS means the process survived and host RSS did not violate these tripwires after one finite stress-stream invocation. It does not mean streaming continued for 180 seconds.

## Screenshots

The producer captures:

- `finite-fixture-early.png` at or after ~8 seconds;
- `residency-mid.png` around the midpoint;
- `residency-end.png` after the observation window.

Each must exceed a minimum byte-size sanity check. These images prove only that the Simulator produced nontrivial rendered output at those times. They are not semantic proof of live streaming, visual acceptance, accessibility acceptance, or frame-pacing quality.

## Durable failure evidence

Runner preflight is written under `$RUNNER_TEMP`, outside the checkout tree, **before** checkout. Later build/runtime receipts use the same external artifact directory. The final upload runs under `if: always()` with `if-no-files-found: error`.

A hosted-runner failure, missing Simulator, source mismatch, build failure, process death, screenshot failure, or RSS guardrail failure can therefore leave auditable evidence rather than disappearing behind a failed step.

## What this does not close

This evidence does not close any of the following:

- sustained streaming liveness across the accepted sample window;
- representative repeated chat/tool/History/theme/model workloads;
- multiple-run or relaunch/session-recovery behavior;
- Full Forge mission endurance;
- frame pacing or interaction latency;
- accessibility;
- Local Model inference, RAM, KV-cache, thermal, battery, or energy behavior;
- physical iPhone 12 memory pressure or jetsam behavior;
- physical iPhone 12 / iOS 27 qualification;
- final Preview readiness.

A future representative long-session acceptance rung must use a workload whose semantic progress is machine-verifiable throughout the accepted window, or continuously execute/retrigger bounded journeys with durable progress receipts. Process liveness by itself is not workload liveness.

## Workflow

Producer: `.github/workflows/v14-preview-residency-signal.yml`

Historical draft #263 called the producer a sustained streaming soak. That label was rejected during adversarial review because the finite fixture could complete before the first accepted RSS sample. This recovery intentionally narrows the evidence class rather than pretending a workflow-only change can make a finite app fixture semantically continuous.

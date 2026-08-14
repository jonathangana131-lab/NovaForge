# V14 Preview finite-stream-triggered residency signal

Status: Preview evidence rung only. This document deliberately does **not** claim sustained streaming, representative long-session acceptance, or physical iPhone qualification.

## Purpose

NovaForge needs durable process-survival and gross memory-regression evidence beyond the short existing UI performance traces. The existing `--stress-streaming` fixture is finite; on the reviewed source its programmed producer delay is roughly tens of seconds, not the full 180-second observation window.

This producer therefore invokes the finite streaming stress once, keeps the same NovaForge Simulator process alive, and evaluates a post-warmup **residency** window. No accepted RSS sample is represented as proof that streaming is still active.

## Exact green-run claim

For one exact source commit, a green focused run may prove that:

1. the configured available Simulator has the canonical CoreSimulator iPhone 12 device type and an iOS 27 runtime identifier;
2. the NovaForge app container was absent before the exact-source app was installed, so prior NovaForge app data was not reused;
3. the built `NovaForge.app` embeds the exact requested source commit marker;
4. one `--stress-streaming` invocation launched in that exact app;
5. the same Simulator process survived the full 180-second observation window;
6. host-observed post-45-second RSS stayed inside conservative regression tripwires;
7. early/mid/end Simulator screenshots were nontrivial files; and
8. preflight, identity, source, app-container, sampling, logs, screenshots, and verdict receipts were durably uploaded.

The workflow receipts explicitly write:

- `scope=simulatorFiniteStreamTriggeredResidencySignalOnly`
- `streamingLivenessVerified=false`
- `representativeLongSessionVerified=false`
- `physicalDeviceVerified=false`

Process liveness is not workload liveness.

## Canonical Simulator identity

Display name alone is not qualification authority because Simulator devices can be renamed. The configured UDID must resolve to:

- `deviceTypeIdentifier=com.apple.CoreSimulator.SimDeviceType.iPhone-12`
- a runtime identifier beginning `com.apple.CoreSimulator.SimRuntime.iOS-27-`
- an available device.

The exact UDID, display name, canonical device type identifier, runtime identifier, and pre-qualification state are persisted in `simulator-identity.txt`.

## Fresh NovaForge app-container boundary

A Simulator reboot alone is not a clean-app-state proof. After boot, the producer checks whether `com.joey.NovaForge` already has a data container. If present, it uninstalls the app, then fails closed if the app container is still discoverable.

The receipt records whether an old installation existed and requires `appPresentAfterBoundary=false` before the exact-source app is installed. It also records `simulatorErased=false`: this is a fresh **NovaForge app-container** boundary, not a full Simulator erase or a claim that all system caches were reset.

## Exact source binding

The requested source must be an exact 40-character commit SHA. Checked-out `HEAD` must match it. The build receives `NOVAFORGE_SOURCE_COMMIT=<sha>`, and the produced app's `NovaForgeSourceCommit` Info.plist value must match before install and launch.

## Residency guardrails

The process is sampled every 15 seconds for 180 seconds. Guardrail calculations exclude the first 45 seconds as warmup and require at least six accepted samples.

Conservative Simulator/host-RSS regression tripwires:

- final positive RSS growth from the first accepted sample: <= 128 MiB;
- least-squares RSS slope across accepted samples: <= 768 KiB/s;
- accepted-window RSS span: <= 192 MiB.

These are coarse regression tripwires only. They are not physical iPhone memory budgets, Local Model qualification thresholds, Forge Compact savings targets, or product SLOs.

## Screenshots

The producer captures an early finite-fixture screenshot plus midpoint and end residency screenshots. Each must exceed a minimum byte-size sanity check. They prove only that the Simulator produced nontrivial rendered output at those times; they do not prove streaming liveness, visual acceptance, accessibility, or frame pacing.

## Durable failure evidence

Preflight is written under `$RUNNER_TEMP`, outside the checkout tree, before checkout. Later receipts use the same external artifact directory. The final artifact upload runs under `if: always()` with `if-no-files-found: error`, so checkout/build/runtime failures cannot silently erase the producer's only preflight receipt.

## Not closed by this evidence

This signal does not close:

- sustained streaming liveness across the accepted sample window;
- representative repeated chat/tool/History/theme/model workloads;
- relaunch/session recovery or Full Forge endurance;
- frame pacing, interaction latency, or accessibility;
- Local Model RAM, KV-cache, thermal, battery, or energy behavior;
- physical iPhone 12 memory pressure or jetsam behavior;
- physical iPhone 12 / iOS 27 qualification;
- final Preview readiness.

A future representative long-session rung must expose machine-verifiable workload progress throughout the accepted window or continuously execute/retrigger bounded journeys with durable progress receipts.

## Producer

`.github/workflows/v14-preview-residency-signal.yml`

Historical draft #263 called the observation a sustained streaming soak. Adversarial review rejected that claim because the finite fixture could complete before the first accepted RSS sample. This recovery intentionally narrows the evidence class instead of pretending a workflow-only change can make a finite app fixture semantically continuous.

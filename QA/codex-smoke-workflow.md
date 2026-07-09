# NovaForge Fast Smoke And Tour Workflow

This is the authoritative release QA matrix for fast NovaForge trust checks. Keep this file current when adding or removing smoke screenshots, focused suites, launch fixtures, or cleanup gates.

Use this when NovaForge needs quick simulator proof without opening Xcode.

The preferred path is the guarded fast screenshot script. It reuses the newest built app, installs only when needed, rejects blank launch-frame screenshots by byte size, terminates the app after capture, and can shut the simulator down.

## Fast Single-Screen Proof

Fast Forge mission screenshot from the newest Release app:

```sh
WAIT_SECONDS=1 SHUTDOWN_SIMULATOR_AFTER_CAPTURE=1 scripts/codex-fast-screenshot.sh --open-forge
```

Rebuild once before capture:

```sh
BUILD_FIRST=1 CONFIGURATION=Release WAIT_SECONDS=1 SHUTDOWN_SIMULATOR_AFTER_CAPTURE=1 scripts/codex-sim-smoke.sh --open-forge
```

Capture another entry point:

```sh
WAIT_SECONDS=1 SHUTDOWN_SIMULATOR_AFTER_CAPTURE=1 scripts/codex-fast-screenshot.sh --pending-approval-demo --open-chat
```

Useful fast screenshot knobs:

- `MIN_SCREENSHOT_BYTES=120000` rejects tiny blank launch screenshots.
- `SCREENSHOT_READY_ATTEMPTS=12` controls retry count.
- `SCREENSHOT_READY_INTERVAL=0.75` controls retry spacing.
- `INSTALL_IF_NEWER=1` avoids reinstalling a cached app unless the build changed.
- `TERMINATE_AFTER_CAPTURE=1` keeps the app process from lingering.
- `SHUTDOWN_SIMULATOR_AFTER_CAPTURE=1` leaves the Mac quiet after proof.
- `VERIFY_TOUR_SCREENSHOTS=1` makes the tour fail if an expected frame is missing, unreadable, duplicated, or below the byte floor.
- `VERIFY_UNIQUE_TOUR_SCREENSHOTS=1` makes `scripts/codex-tour-verify.sh` reject repeated frames so a stuck launch/tab does not masquerade as a complete tour.
- `MAX_TOUR_SECONDS=360` makes the tour fail if the complete build/install/screenshot/verifier wrapper exceeds the release budget.

## Primary Surface Tour

Run the multi-screen tour:

```sh
WAIT_SECONDS=1 CONFIGURATION=Release SHUTDOWN_SIMULATOR_AFTER_TOUR=1 scripts/codex-sim-tour.sh
```

The tour uses `scripts/codex-fast-screenshot.sh` by default. If `BUILD_FIRST=1`, it builds once before screenshots with `scripts/codex-sim-smoke.sh`, then reuses one install marker for every step.
The tour reports `Tour duration: ...` on success and fails above `MAX_TOUR_SECONDS` so screenshot proof cannot silently become slow.

Deterministic launch fixtures are compiled for Debug and simulator Release builds so the release screenshot tour can prove real surfaces without API keys, model downloads, or manual setup. They must stay simulator-only outside Debug and must not ship as real device Release behavior.

Tour outputs:

- Screenshots: `NovaForgeScreenshots/codex-tour-<timestamp>/`
- Logs: `QA/codex-tour-<timestamp>/`

The tour verifies all expected screenshots before reporting success. To verify an existing tour folder:

```sh
scripts/codex-tour-verify.sh NovaForgeScreenshots/codex-tour-<timestamp>
```

Verifier output includes `tour-verification-summary.txt` inside the tour folder with bytes, dimensions, and SHA-256 for every required frame.

Tour fixture matrix:

The launch arguments still use compatibility aliases because older fixtures, Siri intents, and scripts route through `AppTab.resolve(_:)`. New scripts should prefer canonical `--open-forge`, `--open-workspace`, `--open-history`, and `--open-control`; the tour keeps the compatibility names below to avoid churn in existing screenshot filenames. The expected user-facing surfaces are Forge, Workspace, History, and Control.

Before editing this matrix, run the static manifest guard so the runner and verifier stay aligned:

```sh
TOUR_MANIFEST_CHECK=1 scripts/codex-tour-verify.sh
```

| Step | Launch args | Proves |
| --- | --- | --- |
| `01-chat-default-clean` | `--reset-ui --open-chat` | Compatibility name; proves cold launch defaults to clean Forge without the pre-redesign project-launch card or duplicate mission status board. |
| `02-project-idle` | `--reset-ui --open-project` | Compatibility name; proves Forge mission command state, one Run action, chosen next step, reason, proof, and approval expectation. |
| `03-project-running` | `--reset-ui --project-running-demo --open-project` | Compatibility name; proves project run active/loading state and live structured progress outside the conversation. |
| `04-project-approval` | `--reset-ui --project-waiting-demo --open-project` | Compatibility name; proves Forge pauses a project mission at an approval gate with pending mutating tool context. |
| `05-project-waiting` | `--reset-ui --project-waiting-demo --open-project` | Compatibility name; intentionally replays the same approval-gate fixture as a stability frame while the verifier still rejects unexpected repeated frames elsewhere. |
| `06-project-blocked` | `--reset-ui --project-blocked-demo --open-project` | Compatibility name; proves true blocker state with failed run, terminal evidence, and recovery next step. |
| `07-project-proof` | `--reset-ui --project-proof-demo --open-project` | Compatibility name; proves completed/proof state with artifact, file change, terminal record, timeline, and proof checkpoint linked. |
| `08-project-resume` | `--reset-ui --project-resume-demo --open-project` | Compatibility name; proves Forge can resume an interrupted project run with the right context. |
| `09-project-auto-continue-countdown` | `--reset-ui --auto-continue-countdown-demo --open-project` | Compatibility name; proves the auto-continue countdown state. |
| `10-runs-proof` | `--reset-ui --project-proof-demo --open-runs` | Compatibility name; proves History agrees with Forge proof/run records. |
| `11-files-proof` | `--reset-ui --project-proof-demo --open-files` | Compatibility name; proves Workspace shows proof artifacts without deleting durable evidence. |
| `12-terminal-live-record` | `--reset-ui --terminal-live-record-demo --open-terminal` | Compatibility name; proves the Workspace terminal proof console and command record state. |
| `13-settings-local-ready` | `--reset-ui --settings-local-model-ready --open-settings` | Compatibility name; proves Control with deterministic local model ready state. |
| `14-chat-pending-approval` | `--reset-ui --pending-approval-demo --open-chat` | Compatibility name; proves Forge keeps approval context attached to the active conversation. |
| `15-theme-matrix-project-running` | `--reset-ui --theme-world=matrixRain --project-running-demo --open-project` | Compatibility name; proves Matrix Rain keeps active Forge mission state legible. |
| `16-theme-midnight-chat-general` | `--reset-ui --theme-world=midnightBlack --open-chat` | Compatibility name; proves Midnight Black keeps the general Forge conversation legible. |
| `17-theme-whitegold-settings` | `--reset-ui --theme-world=whiteGold --settings-local-model-ready --open-settings` | Compatibility name; proves White Gold keeps Control/model readiness legible. |
| `18-theme-arctic-runs-proof` | `--reset-ui --theme-world=arcticGlass --project-proof-demo --open-runs` | Compatibility name; proves Arctic Glass keeps History proof receipts legible. |
| `19-theme-ember-terminal-proof` | `--reset-ui --theme-world=emberCore --terminal-live-record-demo --open-terminal` | Compatibility name; proves Ember Core keeps Workspace terminal proof legible. |
| `20-project-intake-brief` | `--reset-ui --open-project --project-intake-demo` | Compatibility name; proves the mission dossier intake brief can open from Forge. |

## Ten-Minute Trust Gate

Run this bounded sequence before trusting a release-hardening change:

```sh
scripts/codex-focused-tests.sh
scripts/codex-performance-gate.sh
WAIT_SECONDS=1 BUILD_FIRST=1 CONFIGURATION=Release SHUTDOWN_SIMULATOR_AFTER_TOUR=1 scripts/codex-sim-tour.sh
scripts/codex-sim-clean-check.sh
```

Expected proof:

- `scripts/codex-focused-tests.sh` prints `Focused tests passed` and leaves logs in `QA/codex-focused-tests-<timestamp>/`.
- `scripts/codex-performance-gate.sh` reuses the focused `.xctestrun`, prints `Performance budgets passed`, and leaves `performance-summary.txt` plus raw OSLog output in `QA/codex-performance-gate-<timestamp>/`.
- `scripts/codex-sim-tour.sh` prints `Tour passed`, leaves twenty required screenshots in `NovaForgeScreenshots/codex-tour-<timestamp>/`, and writes `tour-verification-summary.txt`.
- `scripts/codex-sim-clean-check.sh` reports the proof simulator is shutdown and no NovaForge, `xcodebuild`, `simctl`, fast screenshot, or tour helper is lingering.

## Focused Code Proof

Run these before trusting workflow changes:

```sh
scripts/codex-focused-tests.sh
```

The helper runs the focused suites below with bounded logs under `QA/codex-focused-tests-<timestamp>/`.
By default it runs one project-based `build-for-testing` phase first in an isolated `QA/codex-focused-tests-<timestamp>/DerivedData` folder, discovers the generated `.xctestrun`, writes that path to `xctestrun.path`, restarts and waits for the proof simulator with `simctl bootstatus`, then runs all focused suites in one `test-without-building` invocation from that file. This keeps the trust gate fast while avoiding package graph resolution in every suite and avoids locking the shared Xcode DerivedData database when another Codex thread is building. Xcode and simulator boot/shutdown commands run through `scripts/codex-timeout-runner.pl`, which records logs and terminates its own process group on timeout. The helper shuts the proof simulator down on exit unless `SHUTDOWN_SIMULATOR_AFTER_TESTS=0`.

For testmanagerd triage, use the slower isolated mode:

```sh
FOCUSED_TEST_MODE=per-suite scripts/codex-focused-tests.sh
```

Manual equivalent:

```sh
scripts/codex-timeout-runner.pl 480 QA/manual-build-for-testing.log xcodebuild -project AgentPad.xcodeproj -scheme AgentPad -configuration Debug -sdk iphonesimulator -destination 'id=4B9AB34A-404C-485F-B0BC-964F24D0AE83' -skipPackageUpdates -skipPackagePluginValidation -skipMacroValidation ONLY_ACTIVE_ARCH=YES CODE_SIGNING_ALLOWED=NO build-for-testing
XCTESTRUN_PATH="$(find "$HOME/Library/Developer/Xcode/DerivedData" -path '*AgentPad-*/Build/Products/AgentPad_*.xctestrun' -print | sort | tail -n 1)"
scripts/codex-timeout-runner.pl 240 QA/manual-AgentRuntimeLifecycleTests.log xcodebuild -xctestrun "$XCTESTRUN_PATH" -destination 'id=4B9AB34A-404C-485F-B0BC-964F24D0AE83' test-without-building -only-testing:AgentPadTests/AgentRuntimeLifecycleTests
scripts/codex-timeout-runner.pl 240 QA/manual-ProjectFoundationTests.log xcodebuild -xctestrun "$XCTESTRUN_PATH" -destination 'id=4B9AB34A-404C-485F-B0BC-964F24D0AE83' test-without-building -only-testing:AgentPadTests/ProjectFoundationTests
scripts/codex-timeout-runner.pl 240 QA/manual-CommandRunnerTests.log xcodebuild -xctestrun "$XCTESTRUN_PATH" -destination 'id=4B9AB34A-404C-485F-B0BC-964F24D0AE83' test-without-building -only-testing:AgentPadTests/CommandRunnerTests
scripts/codex-timeout-runner.pl 240 QA/manual-FilesWorkspacePersistenceTests.log xcodebuild -xctestrun "$XCTESTRUN_PATH" -destination 'id=4B9AB34A-404C-485F-B0BC-964F24D0AE83' test-without-building -only-testing:AgentPadTests/FilesWorkspacePersistenceTests
```

`ProjectFoundationTests` is currently a focused test class inside `AgentRuntimeLifecycleTests.swift`, not a separate source file. Keep the `-only-testing:AgentPadTests/ProjectFoundationTests` selector because Xcode addresses test classes by test bundle/class name.

Coverage map:

| Area | Primary proof |
| --- | --- |
| Launch recovery | `AgentRuntimeLifecycleTests` launch selection and interrupted tool recovery tests. |
| Approval gating | `AgentRuntimeLifecycleTests` approve/reject/stop pending approval tests plus tour step `04-project-approval`. |
| Approved tool state | `ProjectFoundationTests/testProjectSummaryTreatsApprovedRunAsRunningNotPendingApproval` inside `AgentRuntimeLifecycleTests.swift`. |
| Project source of truth | `ProjectFoundationTests` launch repair/project scoping tests plus `testProjectLatestProofPrefersNewerFailedRunOverOlderArtifact`, currently inside `AgentRuntimeLifecycleTests.swift`. |
| Files workspace state | `FilesWorkspacePersistenceTests` project/settings/active-project workspace save and rollback tests plus tour step `11-files-proof`. |
| Run history correctness | `ProjectFoundationTests/testDeletingRunLogDetachesProofProvenanceWithoutDeletingProof` inside `AgentRuntimeLifecycleTests.swift`. |
| Artifacts and proof ledger | Focused gate covers `ProjectFoundationTests/testProofLedgerDerivesFromArtifactsRunsFilesTerminalAndEvents`, currently inside `AgentRuntimeLifecycleTests.swift`; `WorkspaceArtifactTests` is adjacent deeper proof outside the default focused helper. |
| Terminal records | `CommandRunnerTests` terminal merge/filter tests plus `ProjectFoundationTests/testTerminalMutationFileChangeLinksToTerminalCommand`, currently inside `AgentRuntimeLifecycleTests.swift`. |
| Local model state | `AgentRuntimeLifecycleTests` local model fixture/status/download preservation tests plus tour step `13-settings-local-ready`. |
| Project continuation | Focused gate covers `ProjectFoundationTests/testProjectContinuationRuntimeCreatesActiveProjectEvidenceOnly`, currently inside `AgentRuntimeLifecycleTests.swift`; `LocalAgentPlannerTests` is adjacent deeper proof outside the default focused helper. |

## Performance Budget Proof

Run this after `scripts/codex-focused-tests.sh` so it can reuse the freshly built `.xctestrun` without another build:

```sh
scripts/codex-performance-gate.sh
```

The gate runs `AgentPadUITests/testProjectLiquidGlassPerformanceTraceFlow` with `--profile-frame-rate`, `--profile-events`, and deterministic project auto-scroll, captures NovaForge performance OSLog output, then fails if any required metric is missing or above/below budget.
It ignores the first tab-switch timing sample by default (`IGNORE_INITIAL_TAB_SWITCH_SAMPLES=1`) because launch arguments route the app from its default Forge surface to the requested opening surface before the user-tab-switch loop begins.

Default budgets:

| Metric | Budget |
| --- | --- |
| Project idle FPS | average >= `MIN_PROJECT_IDLE_FPS=45` |
| Project scroll FPS | average >= `MIN_PROJECT_SCROLL_FPS=40` |
| Chat streaming FPS | average >= `MIN_CHAT_STREAMING_FPS=40` |
| Tab switch duration | after ignored launch-routing sample, average <= `MAX_TAB_SWITCH_AVERAGE_MS=900`, peak <= `MAX_TAB_SWITCH_PEAK_MS=1500` |
| Project idle worst frame | average <= `MAX_PROJECT_IDLE_AVG_WORST_FRAME_MS=120`, peak <= `MAX_PROJECT_IDLE_PEAK_WORST_FRAME_MS=250` |
| Project scroll worst frame | average <= `MAX_PROJECT_SCROLL_AVG_WORST_FRAME_MS=180`, peak <= `MAX_PROJECT_SCROLL_PEAK_WORST_FRAME_MS=500` |
| Chat streaming worst frame | average <= `MAX_CHAT_STREAMING_AVG_WORST_FRAME_MS=150`, peak <= `MAX_CHAT_STREAMING_PEAK_WORST_FRAME_MS=650` |
| Project idle hitches | max <= `MAX_PROJECT_IDLE_HITCH_COUNT=24` |
| Project scroll hitches | max <= `MAX_PROJECT_SCROLL_HITCH_COUNT=30` |
| Chat streaming hitches | max <= `MAX_CHAT_STREAMING_HITCH_COUNT=30` |

If no reusable focused test bundle exists, run `BUILD_IF_NEEDED=1 scripts/codex-performance-gate.sh`; that is slower and should stay outside the default fast trust gate unless necessary.

Fast gate does not fully cover:

- Real paid-provider requests, revoked API keys, or custom endpoint outages beyond unit-level/provider-sanitizer behavior.
- Real multi-gigabyte local model inference on physical hardware; the fast tour uses deterministic local model fixtures.
- Full XCUITest regression inventory; the fast tour favors bounded screenshot proof over every long UI test.
- Physical iPhone install/signing/provisioning.
- Full accessibility audit across every Dynamic Type size and VoiceOver rotor path.
- Exhaustive Liquid Glass frame-time analysis across every device/runtime; the fast performance gate enforces the Project scroll, tab switch, and Chat streaming budgets on the proof simulator, while deep performance sweeps remain separate.

## Cleanup Check

After any simulator proof, verify the Mac is quiet:

```sh
scripts/codex-sim-clean-check.sh
```

Manual checks if the helper fails:

```sh
xcrun simctl list devices | rg 'Booted|4B9AB34A'
```

```sh
ps -axo pid,ppid,stat,etime,%cpu,%mem,comm,args | awk '$0 ~ /NovaForge\.app\/NovaForge|codex-fast-screenshot|codex-sim-tour|xcodebuild|simctl/ { print }'
```

Expected result:

- `NovaForge-iPhone12-Clean (4B9AB34A-404C-485F-B0BC-964F24D0AE83) (Shutdown)`
- no persistent `NovaForge`, `xcodebuild`, `codex-fast-screenshot`, or `codex-sim-tour` process hits beyond the check command itself.

## Simulator Health

The scripts fail fast if CoreSimulator looks wedged. If the tour prints `CoreSimulator appears wedged before starting the NovaForge tour`, do not keep retrying in the same macOS session.

First try a bounded shutdown/boot:

```sh
xcrun simctl shutdown 4B9AB34A-404C-485F-B0BC-964F24D0AE83
xcrun simctl boot 4B9AB34A-404C-485F-B0BC-964F24D0AE83
xcrun simctl bootstatus 4B9AB34A-404C-485F-B0BC-964F24D0AE83 -b
```

Bypass the preflight only for diagnosis:

```sh
CHECK_SIMULATOR_HEALTH=0 SIMCTL_TIMEOUT=20 scripts/codex-sim-tour.sh
```

If simulator runtime processes are stuck in uninterruptible or zombie state, restart macOS or log out/back in before running another long proof.

## Legacy Smoke Script

`scripts/codex-sim-smoke.sh` remains the legacy build/install/launch helper and is still useful for a plain rebuild:

```sh
BUILD_FIRST=1 LAUNCH_APP=0 CAPTURE_SCREENSHOT=0 scripts/codex-sim-smoke.sh
```

For screenshot proof, prefer `scripts/codex-fast-screenshot.sh` or `scripts/codex-sim-tour.sh`.

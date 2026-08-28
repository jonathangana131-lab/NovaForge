# NovaForge Test Lanes And Visual Proof

This is the authoritative NovaForge verification guide. The test system builds one reusable XCTest bundle, boots one simulator, and separates fast behavioral proof from exhaustive release and screenshot work.

## Test Lanes

Use one entry point:

```sh
scripts/codex-test.sh smoke
scripts/codex-test.sh critical
scripts/codex-test.sh unit
scripts/codex-test.sh visual
scripts/codex-test.sh release
```

| Lane | Purpose | Contents | Screenshots |
| --- | --- | --- | --- |
| `smoke` | Tight edit loop | Four launch/chat/provider/reasoning journeys | Off except required pixel proof |
| `critical` | Pull request and pre-release gate | Source contracts, all package and app unit tests, and at most 16 high-value UI journeys | Off; XCTest retains failure shots |
| `unit` | Agent/runtime work | Source contracts, package tests, and all app unit tests | Off |
| `visual` | UI review | Ten synchronized journeys covering the major surfaces | Written to the lane's `screenshots/` folder |
| `release` | Scheduled/manual exhaustive gate | Source contracts, package tests, every unit test, and every UI journey | Off; failures still retain XCTest diagnostics |

The runner incrementally uses `QA/DerivedData/codex-tests/`, writes the reusable `.xctestrun` path into each timestamped log folder, and runs `test-without-building`. A PID lock prevents two Apple-tooling lanes from colliding. Local smoke/critical/unit lanes skip the expensive post-test `.xcresult` archive; CI can request one by setting `RESULT_BUNDLE_PATH`, and release enables it by default. `scripts/codex-focused-tests.sh` remains only as a compatibility alias for the `unit` lane.

The critical lane is deliberately capped at 16 UI journeys and smoke at five. Add exhaustive permutations to release, and add screenshot-only coverage to visual. Do not grow the everyday lane just because a test exists.

Use this when NovaForge needs quick simulator proof without opening Xcode.

The preferred path is the guarded fast screenshot script. It reuses the newest built app, installs only when needed, rejects blank launch-frame screenshots by byte size, terminates the app after capture, and can shut the simulator down.

## Fast Single-Screen Proof

Fast Project screenshot from the newest Release app:

```sh
WAIT_SECONDS=1 SHUTDOWN_SIMULATOR_AFTER_CAPTURE=1 scripts/codex-fast-screenshot.sh --open-project
```

Rebuild once before capture:

```sh
BUILD_FIRST=1 CONFIGURATION=Release scripts/codex-sim-tour.sh
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
- Tour screenshot verification is mandatory; the tour fails if an expected frame is missing, unreadable, duplicated, below the byte floor, or lacks its recorded fixture/provenance metadata.
- Unique screenshot verification is mandatory: `scripts/codex-tour-verify.sh` rejects repeated frames, and fails closed if a caller tries to disable the guard.
- Semantic OCR verification and tour provenance verification are also mandatory. The verifier records and checks the source-tree fingerprint, exact app-bundle hash, and fixture manifest for every run.
- `STEP_TIMEOUT=45` bounds each tour launch/capture step; `OCR_TIMEOUT=60` and `IMAGE_INFO_TIMEOUT=20` bound verifier subprocesses; `MAX_WAIT_SECONDS=30` bounds the legacy smoke post-launch wait.
- `MAX_TOUR_SECONDS=360` makes the tour fail if the complete build/install/screenshot/verifier wrapper exceeds the release budget.

## Primary Surface Tour

Run the multi-screen tour:

```sh
WAIT_SECONDS=1 CONFIGURATION=Release SHUTDOWN_SIMULATOR_AFTER_TOUR=1 scripts/codex-sim-tour.sh
```

The tour uses `scripts/codex-fast-screenshot.sh` by default. If `BUILD_FIRST=1`, it builds once before screenshots with `scripts/codex-sim-smoke.sh`, then reuses one install marker for every step. Each run gets an isolated output directory, `tour-metadata.txt` with source/build hashes, and `tour-fixtures.tsv` mapping every screenshot to its launch fixture.
The tour reports `Tour duration: ...` on success and fails above `MAX_TOUR_SECONDS` so screenshot proof cannot silently become slow.

Deterministic launch fixtures are compiled for Debug and simulator Release builds so the release screenshot tour can prove real surfaces without API keys, model downloads, or manual setup. They must stay simulator-only outside Debug and must not ship as real device Release behavior.

Tour outputs:

- Screenshots: `NovaForgeScreenshots/codex-tour-<timestamp>/`
- Logs: `QA/codex-tour-<timestamp>/`

The tour verifies all expected screenshots before reporting success. To verify an existing tour folder:

```sh
scripts/codex-tour-verify.sh NovaForgeScreenshots/codex-tour-<timestamp>
```

Verifier output includes `tour-verification-summary.txt` inside the tour folder with provenance, fixture identity, bytes, dimensions, and SHA-256 for every required frame.

Tour fixture matrix:

| Step | Launch args | Proves |
| --- | --- | --- |
<!-- matrix below intentionally uses distinct approval/waiting fixtures -->
| `01-chat-default-clean` | `--reset-ui --open-chat` | Cold launch defaults to clean Forge chat. |
| `02-mission-dossier-idle` | `--reset-ui --open-project --open-mission-dossier-demo` | Idle mission dossier and next action. |
| `03-mission-dossier-running` | `--reset-ui --project-running-demo --open-project --open-mission-dossier-demo` | Active ProjectOS run and structured progress. |
| `04-chat-pending-approval` | `--reset-ui --pending-approval-demo --open-chat` | Human review sheet for a chat tool request. |
| `05-mission-dossier-waiting` | `--reset-ui --project-waiting-demo --open-project --open-mission-dossier-demo` | Inline mission-dossier approval/waiting state; distinct from the chat sheet. |
| `06-mission-dossier-blocked` | `--reset-ui --project-blocked-demo --open-project --open-mission-dossier-demo` | Failed validation blocker and recovery next step. |
| `07-mission-dossier-proof` | `--reset-ui --project-proof-demo --open-project --open-mission-dossier-demo` | Completed proof state with durable evidence. |
| `08-mission-dossier-resume` | `--reset-ui --project-resume-demo --open-project --open-mission-dossier-demo` | Paused/interrupted mission ready to resume. |
| `09-mission-dossier-auto-continue-countdown` | `--reset-ui --auto-continue-countdown-demo --open-project --open-mission-dossier-demo` | Scheduled auto-continue safety pause. |
| `10-runs-proof` | `--reset-ui --project-proof-demo --open-runs` | History agrees with Project proof records. |
| `11-files-proof` | `--reset-ui --project-proof-demo --open-files` | Workspace proof artifacts. |
| `12-terminal-live-record` | `--reset-ui --terminal-live-record-demo --open-terminal` | Terminal command record state. |
| `13-settings-local-ready` | `--reset-ui --settings-local-model-ready --open-settings` | Deterministic local model ready settings. |
| `14-runs-pending-approval` | `--reset-ui --runs-approval-demo --open-runs` | Approval evidence on History without forcing Chat to the front. |
| `15-theme-matrix-mission-dossier-running` | `--reset-ui --theme-world=matrixRain --project-running-demo --open-project --open-mission-dossier-demo` | Matrix theme with running mission. |
| `16-theme-midnight-chat-general` | `--reset-ui --theme-world=midnightBlack --open-chat` | Midnight theme with general Forge chat. |
| `17-theme-whitegold-settings` | `--reset-ui --theme-world=whiteGold --settings-local-model-ready --open-settings` | White-gold theme with ready settings. |
| `18-theme-arctic-runs-proof` | `--reset-ui --theme-world=arcticGlass --project-proof-demo --open-runs` | Arctic theme with proof history. |
| `19-theme-ember-terminal-proof` | `--reset-ui --theme-world=emberCore --terminal-live-record-demo --open-terminal` | Ember theme with terminal proof. |
| `20-mission-dossier-intake-brief` | `--reset-ui --open-project --open-mission-dossier-demo --project-intake-demo` | Project intake brief and creation surface. |

## Fast Trust Gate

Run this bounded sequence before trusting a release-hardening change:

```sh
scripts/codex-test.sh critical
scripts/codex-performance-gate.sh
WAIT_SECONDS=1 BUILD_FIRST=1 CONFIGURATION=Release SHUTDOWN_SIMULATOR_AFTER_TOUR=1 scripts/codex-sim-tour.sh
scripts/codex-sim-clean-check.sh
```

Expected proof:

- `scripts/codex-test.sh critical` prints `PASS: NovaForge critical lane`, leaves logs in `QA/codex-tests-<timestamp>-critical/`, and reuses one bounded build cache. Set `WRITE_RESULT_BUNDLE=1` or `RESULT_BUNDLE_PATH` when a retained `.xcresult` is required.
- `scripts/codex-performance-gate.sh` reuses that `.xctestrun`, prints `Performance budgets passed`, and leaves `performance-summary.txt` plus raw OSLog output in `QA/codex-performance-gate-<timestamp>/`.
- `scripts/codex-ai-streaming-video-proof.sh` preserves video, screenshots, contact sheet, and logs while removing its managed `QA/DerivedData/codex-ai-streaming-video-proof/` build cache on exit by default. Set `KEEP_DERIVED_DATA=1` only for debugging; custom `DERIVED_DATA` paths are preserved.
- `scripts/codex-sim-tour.sh` prints `Tour passed`, leaves twenty required screenshots in `NovaForgeScreenshots/codex-tour-<timestamp>/`, and writes `tour-metadata.txt`, `tour-fixtures.tsv`, and `tour-verification-summary.txt`.
- `scripts/codex-sim-clean-check.sh` reports the proof simulator is shutdown and no NovaForge, `xcodebuild`, `simctl`, fast screenshot, or tour helper is lingering.

## Unit-Only Proof

Run these before trusting workflow changes:

```sh
scripts/codex-test.sh unit
```

The unit lane still compiles the UI target into the reusable bundle so the next smoke, performance, or visual lane does not rebuild the app. It selects only `AgentPadTests` at execution time. Set `RESET_DERIVED_DATA_BEFORE_BUILD=1` only for an intentionally clean proof; normal runs should keep the incremental cache. All build, test, package, boot, and shutdown work remains bounded by `scripts/codex-timeout-runner.pl`.

Coverage map:

| Area | Primary proof |
| --- | --- |
| Launch recovery | `AgentRuntimeLifecycleTests` launch selection and interrupted tool recovery tests. |
| Approval gating | `AgentRuntimeLifecycleTests` approve/reject/stop pending approval tests plus distinct tour steps `04-chat-pending-approval`, `05-mission-dossier-waiting`, and `14-runs-pending-approval`. |
| Approved tool state | `ProjectFoundationTests/testProjectSummaryTreatsApprovedRunAsRunningNotPendingApproval`. |
| Project OS source of truth | `ProjectFoundationTests` launch repair/project scoping tests plus `testProjectLatestProofPrefersNewerFailedRunOverOlderArtifact`. |
| Files workspace state | `FilesWorkspacePersistenceTests` project/settings/active-project workspace save and rollback tests plus tour step `11-files-proof`. |
| Run history correctness | `ProjectFoundationTests/testDeletingRunLogDetachesProofProvenanceWithoutDeletingProof`. |
| Artifacts and proof ledger | `WorkspaceArtifactTests` plus `ProjectFoundationTests/testProofLedgerDerivesFromArtifactsRunsFilesTerminalAndEvents`. |
| Terminal records | `CommandRunnerTests` terminal merge/filter tests plus `ProjectFoundationTests/testTerminalMutationFileChangeLinksToTerminalCommand`. |
| Local model state | `AgentRuntimeLifecycleTests` local model fixture/status/download preservation tests plus tour step `13-settings-local-ready`. |
| Project continuation | `LocalAgentPlannerTests` continuation tests plus `ProjectFoundationTests/testProjectContinuationRuntimeCreatesActiveProjectEvidenceOnly`. |

## Performance Budget Proof

Run this after any `scripts/codex-test.sh` app lane so it can reuse the freshly built `.xctestrun` without another build:

```sh
scripts/codex-performance-gate.sh
```

The gate runs `AgentPadUITests/testProjectLiquidGlassPerformanceTraceFlow` with `--profile-frame-rate`, `--profile-events`, and deterministic project auto-scroll, captures NovaForge performance OSLog output, then fails if any required metric is missing or above/below budget.
It ignores the first tab-switch timing sample by default (`IGNORE_INITIAL_TAB_SWITCH_SAMPLES=1`) because launch arguments route the app from its default Chat tab to the requested opening tab before the user-tab-switch loop begins.
Before booting Simulator, the gate also checks the shared Mac's one-minute load against `MAX_HOST_LOAD_PER_CPU=4`. It exits 75 instead of publishing misleading FPS when unrelated host work has saturated the machine. `REQUIRE_QUIET_HOST=0` is diagnostic-only and must not be used for release proof.

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

If no reusable test bundle exists, run `BUILD_IF_NEEDED=1 scripts/codex-performance-gate.sh`; that is slower and should stay outside the default fast trust gate unless necessary. Self-builds use `QA/DerivedData/codex-performance-gate/` and remove that managed cache on exit by default.

Fast gate does not fully cover:

- Real paid-provider requests, revoked API keys, or custom endpoint outages beyond unit-level/provider-sanitizer behavior.
- Real multi-gigabyte local model inference on physical hardware; the fast tour uses deterministic local model fixtures.
- Full XCUITest regression inventory; the weekly/manual `release` lane owns every UI journey in the current test target.
- Physical iPhone install/signing/provisioning.
- Full accessibility audit across every Dynamic Type size and VoiceOver rotor path.
- Exhaustive Liquid Glass frame-time analysis across every device/runtime; the fast performance gate enforces the Project scroll, tab switch, and Chat streaming budgets on the proof simulator, while deep performance sweeps remain separate.

## Live Provider Simulator Canaries

Build the UI test bundle first, then run the anonymous Zen canary against the
exact `.xctestrun` that will back the release proof. Set both environment forms
because Xcode versions differ in whether shell variables reach the XCTest runner
with a `TEST_RUNNER_` prefix:

```sh
NOVAFORGE_RUN_SIMULATOR_ZEN_CANARY=1 \
TEST_RUNNER_NOVAFORGE_RUN_SIMULATOR_ZEN_CANARY=1 \
xcodebuild test-without-building \
  -xctestrun /absolute/path/to/AgentPad_iphonesimulator26.1-x86_64.xctestrun \
  -destination 'platform=iOS Simulator,id=4B9AB34A-404C-485F-B0BC-964F24D0AE83' \
  -only-testing:AgentPadUITests/AgentPadUITests/testSimulatorAnonymousZenProviderCanaryCompletesAndPersists
```

The ChatGPT subscription canary is optional additional coverage. First sign in
through NovaForge Control inside that exact Simulator. Do not erase the
Simulator, reset its content, or uninstall NovaForge afterward: the canary
intentionally consumes the app-owned Keychain session and never copies a token
through a test argument, environment variable, log, or screenshot.

```sh
NOVAFORGE_RUN_SIMULATOR_CHATGPT_CANARY=1 \
TEST_RUNNER_NOVAFORGE_RUN_SIMULATOR_CHATGPT_CANARY=1 \
xcodebuild test-without-building \
  -xctestrun /absolute/path/to/AgentPad_iphonesimulator26.1-x86_64.xctestrun \
  -destination 'platform=iOS Simulator,id=4B9AB34A-404C-485F-B0BC-964F24D0AE83' \
  -only-testing:AgentPadUITests/AgentPadUITests/testSimulatorChatGPTProviderCanaryCompletesAndPersists
```

Run the exact screenshot route separately after the standard ChatGPT canary.
This proof resets ordinary UI/run state, explicitly reselects ChatGPT GPT-5.5
and UltraCode, observes the delegated-run rail, rejects adapter/recovery UI,
and requires the visible integrator request, response marker, provider/model,
and Completed result to survive in History:

```sh
NOVAFORGE_RUN_SIMULATOR_CHATGPT_ULTRACODE_CANARY=1 \
TEST_RUNNER_NOVAFORGE_RUN_SIMULATOR_CHATGPT_ULTRACODE_CANARY=1 \
xcodebuild test-without-building \
  -xctestrun /absolute/path/to/AgentPad_iphonesimulator26.1-x86_64.xctestrun \
  -destination 'platform=iOS Simulator,id=4B9AB34A-404C-485F-B0BC-964F24D0AE83' \
  -only-testing:AgentPadUITests/AgentPadUITests/testSimulatorChatGPTUltraCodeCanaryCompletesAndPersists
```

All three canaries require a completed assistant bubble and a Completed
History receipt. The anonymous Zen canary remains the credential-free baseline
used by the schema-v2 phone-install receipt. The UltraCode canary has a bounded
17-minute XCTest allowance because it performs three real isolated worker runs
and one real visible integrator run; any known failure surface aborts its polling
early instead of consuming that allowance.

## Physical iPhone Update

The phone helper is fail-closed and never contacts a device by default. First prepare and audit the signed candidate without device contact:

```sh
PREPARE_ONLY=1 CONFIGURATION=Release scripts/run-on-iphone.sh
```

After the exact same clean commit and version pass the live-provider XCTest on Simulator, create a schema-v2 proof receipt. The receipt generator independently audits the signed iPhoneOS candidate, hashes the exact Simulator app, log, and screenshot, derives its timestamp from the named zero-failure XCTest result, and refuses evidence older than 30 minutes:

```sh
SIMULATOR_APP_PATH=/absolute/path/to/Debug-iphonesimulator/NovaForge.app \
DEVICE_CANDIDATE_APP_PATH=/absolute/path/to/Release-iphoneos/NovaForge.app \
PROVIDER_EVIDENCE_LOG=/absolute/path/to/live-provider-test.log \
PROVIDER_EVIDENCE_SCREENSHOT=/absolute/path/to/live-provider-proof.png \
PROVIDER_ID=openCodeZen \
RESPONSE_MARKER=NF_SIMULATOR_BUILD3 \
PROVIDER_TEST_IDENTIFIER=AgentPadUITests.AgentPadUITests/testSimulatorAnonymousZenProviderCanaryCompletesAndPersists \
OUT_RECEIPT=/absolute/path/to/simulator-proof-receipt.json \
scripts/create-simulator-proof-receipt.sh
```

Only then opt in to installing that already-audited candidate:

```sh
ALLOW_DEVICE_INSTALL=1 BUILD_FIRST=0 \
APP_PATH=/absolute/path/to/Release-iphoneos/NovaForge.app \
SIMULATOR_PROOF_RECEIPT=/absolute/path/to/simulator-proof-receipt.json \
scripts/run-on-iphone.sh
```

Immediately before install, the helper again requires clean committed source, rejects untracked compiled source, re-verifies the source commit embedded inside both app bundles, re-audits the signed iPhoneOS bundle, and rehashes the Simulator app plus provider evidence. It then writes logs under `QA/phone-update-*`, records `QA/latest-phone-update-dir.txt`, checks CoreDevice/USB reachability, installs with `devicectl`, launches `com.joey.NovaForge`, and verifies the NovaForge process. If the phone is paired but unavailable, it exits with a clear `PHONE UPDATE BLOCKED` message.

Useful knobs:

- `APP_PATH=/path/to/NovaForge.app` reuses an already-built app.
- `PREPARE_ONLY=1` prepares and audits the signed candidate with no device commands.
- `ALLOW_DEVICE_INSTALL=1` is mandatory for the final install and is accepted only with a fresh schema-v2 Simulator proof receipt.
- `WAIT_FOR_DEVICE=0` performs one fast reachability check and exits if the phone is unavailable.
- `MAX_ATTEMPTS=120 SLEEP_SECONDS=10` waits up to ~20 minutes for unlock/replug/trust recovery.

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

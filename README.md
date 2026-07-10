# NovaForge

**NovaForge is an on-device AI agent workspace for iOS.** It gives a project-scoped agent a place to plan, ask for approval, change files, leave terminal/tool evidence, and preserve a history of what happened. The current app is a SwiftUI + SwiftData iOS workspace with local llama.cpp inference, optional OpenAI-compatible providers, sandboxed file/tool execution, artifacts, run receipts, widgets, and release screenshot proof.

## Product model

NovaForge is organized around one loop: tell the agent what to do, watch it work, approve risky steps, and inspect the proof.

- **Forge** — the main loop: chat, live mission strip, project scope, inline approvals, stop/continue controls, and the mission dossier.
- **Workspace** — the durable workbench: generated files, code editor, artifact previews, file search/comparison, and the terminal proof console.
- **History** — the audit trail: run receipts, replay, grouped history, proof checkpoints, and recovery context.
- **Control** — the control plane: provider/model readiness, local model management, autonomy settings, appearance, and app configuration.

Projects are a context, not a separate tab. The user stays inside a project scope while moving through Forge, Workspace, History, and Control. The detailed product and release direction lives in [docs/release-plan.md](docs/release-plan.md).

## Stack

- **UI:** SwiftUI for iOS 26 with Liquid Glass APIs behind availability checks and fallbacks.
- **Design:** Five themes: Matrix Rain, Midnight Black, White Gold, Arctic Glass, and Ember Core.
- **AI:** Local on-device inference through [`swift-llama-cpp`](Vendor/swift-llama-cpp) plus optional OpenAI-compatible provider support.
- **Persistence:** SwiftData in `NovaForge.store`.
- **Sandbox:** Workspace-scoped file tools, bounded reads/search/diffs, command validation, artifact detection, and approval-gated mutating tools.
- **Project:** `AgentPad.xcodeproj`, scheme `AgentPad`, bundle `com.joey.NovaForge`. `AgentPad` is still the internal Xcode/project name; NovaForge is the product name.

## Build

```sh
xcodebuild -project AgentPad.xcodeproj -scheme AgentPad -configuration Debug -sdk iphonesimulator CODE_SIGNING_ALLOWED=NO build
```

## Fast verification

Use the focused trust gate before release-hardening changes:

```sh
scripts/codex-focused-tests.sh
scripts/codex-performance-gate.sh
WAIT_SECONDS=1 BUILD_FIRST=1 CONFIGURATION=Release SHUTDOWN_SIMULATOR_AFTER_TOUR=1 scripts/codex-sim-tour.sh
scripts/codex-sim-clean-check.sh
```

The detailed verification matrix lives in [QA/codex-smoke-workflow.md](QA/codex-smoke-workflow.md). It documents the focused test suites, screenshot tour, performance budgets, simulator cleanup, deterministic launch fixtures, and gaps that still require deeper physical-device or provider testing.

## CI

Every push to `main` triggers the GitHub Actions pipeline in [ci/pipeline.sh](ci/pipeline.sh). The pipeline builds the Release simulator app, verifies the widget extension is embedded, walks the current NovaForge surfaces through launch fixtures, captures screenshots and short videos, and publishes captures/log tails to the `ci-shots` branch.

CI expects required source assets, including the app icon, to already be present in the repository. It should not repair missing source assets by downloading mutable external archives or committing back to the source branch during a release proof run.

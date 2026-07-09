# NovaForge Release Plan

NovaForge is a project-scoped, on-device AI agent workspace for iOS. The app contract is simple: give the user one place to describe work, watch the agent act, approve risky steps, inspect changed files, and keep durable proof of what happened.

This plan is the source of truth for the current app direction. It should stay aligned with `README.md`, `AGENTS.md`, `QA/codex-smoke-workflow.md`, and the launch fixtures in `scripts/`.

## Product contract

NovaForge should feel like a trustworthy agent workbench, not a generic chat shell. A release-ready build must make these guarantees clear:

- The user can start or resume a project-scoped mission from Forge.
- Risky or mutating work is approval-gated before it changes durable state.
- Workspace shows the files, artifacts, comparisons, and terminal proof created by the agent.
- History preserves run receipts, replay context, checkpoints, and recovery evidence.
- Control owns provider/model readiness, local model management, autonomy, appearance, and app configuration.
- The app can prove its important states with deterministic simulator fixtures before a release.

`AgentPad` remains the internal Xcode project, scheme, and legacy codebase name. `NovaForge` is the product name and the user-facing release identity.

## Four-surface vocabulary

Use the current four-surface vocabulary in product copy, QA descriptions, screenshots, release notes, and new user-facing strings:

| Surface | Owns | Legacy launch aliases |
| --- | --- | --- |
| Forge | Chat, mission strip, project scope, inline approvals, stop/continue controls, and the mission dossier entry point. | `--open-chat`, `--open-project` |
| Workspace | Generated files, code editing, artifact previews, file search/comparison, and terminal proof. | `--open-files`, `--open-terminal` |
| History | Run receipts, replay, grouped history, proof checkpoints, and recovery context. | `--open-runs` |
| Control | Provider/model readiness, local model management, autonomy, appearance, and app settings. | `--open-settings` |

Canonical launch flags should be preferred in new scripts and documentation: `--open-forge`, `--open-workspace`, `--open-history`, and `--open-control`. Legacy aliases must keep working for existing fixtures, Siri intents, and older QA scripts.

## Release-readiness proof

A release-hardening change is not trusted until the fast gate can prove the app shape:

```sh
scripts/codex-focused-tests.sh
scripts/codex-performance-gate.sh
WAIT_SECONDS=1 BUILD_FIRST=1 CONFIGURATION=Release SHUTDOWN_SIMULATOR_AFTER_TOUR=1 scripts/codex-sim-tour.sh
scripts/codex-sim-clean-check.sh
```

The fast gate covers focused runtime tests, performance budgets, deterministic screenshot proof, and simulator cleanup. Before editing the tour matrix, run the static manifest guard:

```sh
TOUR_MANIFEST_CHECK=1 scripts/codex-tour-verify.sh
```

That guard compares `scripts/codex-sim-tour.sh` with `scripts/codex-tour-verify.sh` so the runner and verifier do not silently drift.

## Safe first-wave scope

The first implementation wave should prefer high-confidence changes that strengthen trust without redesigning the app:

- Keep product vocabulary aligned across README, AGENTS, QA docs, launch flags, and demo fixtures.
- Harden proof scripts so screenshots fail closed instead of accepting SpringBoard or blank frames.
- Keep CI deterministic by requiring source assets to exist in the repo instead of downloading mutable repair archives.
- Add static preflight checks for tour matrices and bounded logs.
- Preserve internal Swift type names, project names, schemes, and accessibility identifiers unless a test-backed migration explicitly requires changing them.

## Out-of-scope risky rewrites

Do not bundle these into the first wave:

- Renaming the `AgentPad` Xcode project, scheme, bundle wiring, or build products.
- Renaming internal `ProjectOS*` types, files, ledgers, or persistence models.
- Broad SwiftUI layout rewrites of Forge, Workspace, History, or Control.
- Changing accessibility identifiers just to match new vocabulary.
- Expanding focused test suites before measuring runtime and stability.
- Claiming coverage for physical-device signing, real paid-provider outages, real multi-gigabyte local model inference, or full accessibility audits without running dedicated proof.

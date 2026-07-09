# NovaForge iOS Agent Notes

## Project

- App name: NovaForge
- Xcode project: `AgentPad.xcodeproj`
- Shared scheme: `AgentPad`
- App bundle id: `com.joey.NovaForge`
- Built simulator app: `NovaForge.app`
- Known simulator id: `4B9AB34A-404C-485F-B0BC-964F24D0AE83`

## Preferred iOS Tooling

- XcodeBuildMCP is registered globally in Codex as `XcodeBuildMCP`.
- If the MCP tools are not visible in the current thread, start a fresh Codex thread/session after config reload.
- Prefer XcodeBuildMCP for simulator discovery, session defaults, build/run, UI description, screenshots, and log capture.
- Fall back to the repo scripts below when the MCP server is unavailable.

## Commands

Build for simulator:

```sh
xcodebuild -project AgentPad.xcodeproj -scheme AgentPad -configuration Debug -sdk iphonesimulator CODE_SIGNING_ALLOWED=NO build
```

Run focused tests:

```sh
xcodebuild -project AgentPad.xcodeproj -scheme AgentPad -configuration Debug -sdk iphonesimulator CODE_SIGNING_ALLOWED=NO test
```

Run the canonical fast trust gate before release-hardening changes:

```sh
scripts/codex-focused-tests.sh
scripts/codex-performance-gate.sh
WAIT_SECONDS=1 BUILD_FIRST=1 CONFIGURATION=Release SHUTDOWN_SIMULATOR_AFTER_TOUR=1 scripts/codex-sim-tour.sh
scripts/codex-sim-clean-check.sh
```

Capture a quick single-screen proof when a full tour is unnecessary:

```sh
WAIT_SECONDS=1 SHUTDOWN_SIMULATOR_AFTER_CAPTURE=1 scripts/codex-fast-screenshot.sh --open-forge
```

Useful launch arguments already supported by the smoke/tour scripts:

- `--reset-ui`
- `--open-forge` (canonical Forge entry)
- `--open-workspace` (canonical Workspace entry)
- `--open-history` (canonical History entry)
- `--open-control` (canonical Control entry)
- `--open-chat` (legacy alias; lands on Forge)
- `--open-project` (legacy alias; lands on Forge with mission state on the strip)
- `--open-files` (legacy alias; lands on Workspace)
- `--open-runs` (legacy alias; lands on History)
- `--open-terminal` (legacy alias; opens the Workspace terminal proof console)
- `--open-settings` (legacy alias; lands on Control)
- `--first-run-local-model-missing`
- `--settings-local-model-ready`
- `--pending-approval-demo`

## Four-Tab Architecture (structural redesign, July 2026)

- Tabs: **Forge** (chat + live mission strip + inline approvals — the loop),
  **Workspace** (files, artifact shelf, terminal), **History** (run
  receipts), **Control** (settings). The current app plan and release scope
  live in [docs/release-plan.md](docs/release-plan.md).
- Projects are a context, not a tab: the scope pill in the Forge header
  switches projects; the full project dashboard presents as the modal
  "mission dossier" (`MissionDossierCover` in `ForgeChrome.swift`,
  presented from `AppRootView.missionDossierCover`).
- `AppTab` keeps legacy static aliases (`.chat`, `.project`, `.files`,
  `.runs`, `.settings`, `.terminal`) and `AppTab.resolve(_:)` so old launch
  args, Siri intents, and fixtures keep routing.
- Forge chrome lives in `AgentPad/Views/ForgeChrome.swift`: `ForgeHeader`
  (single-deck, never clips, one prioritized `ForgeSignal` chip),
  `ForgeMissionStrip` (Approve/Reject/Stop/countdown inline; also reused on
  History), `MissionDossierCover`.
- `ChatHeaderStrip.swift` is a tombstone — do not resurrect the chip train.
- De-theater rules that keep these surfaces honest: content starts within
  the first quarter of the screen; one fact stated once per screen; search
  and filters appear only when collections are big enough to need them
  (History gates at 6+ runs, Files evidence lenses at 6+ items).

## Working Rules

- Keep SwiftUI edits scoped and reversible.
- Preserve user project state and persistence.
- Prefer existing design components in `AgentPad/Design` and `AgentPad/Views`.
- Use `@State`, `@Binding`, `@Environment`, `@Query`, `.task`, and `.task(id:)` before adding view models.
- Use iOS 26 Liquid Glass APIs only with availability checks and sensible fallbacks.
- Run one long build/simulator command at a time with hard timeouts.
- Do not leave `xcodebuild`, `simctl`, or simulator helper commands running.
- Do not use destructive git commands.


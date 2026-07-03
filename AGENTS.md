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

Build, install, launch, and capture one smoke screenshot:

```sh
BUILD_FIRST=1 scripts/codex-sim-smoke.sh
```

Capture the primary NovaForge surface tour:

```sh
BUILD_FIRST=1 scripts/codex-sim-tour.sh
```

Useful launch arguments already supported by the smoke/tour scripts:

- `--reset-ui`
- `--open-chat`
- `--open-project`
- `--open-files`
- `--open-runs`
- `--open-terminal`
- `--open-settings`
- `--first-run-local-model-missing`
- `--settings-local-model-ready`
- `--pending-approval-demo`

## Working Rules

- Keep SwiftUI edits scoped and reversible.
- Preserve user project state and persistence.
- Prefer existing design components in `AgentPad/Design` and `AgentPad/Views`.
- Use `@State`, `@Binding`, `@Environment`, `@Query`, `.task`, and `.task(id:)` before adding view models.
- Use iOS 26 Liquid Glass APIs only with availability checks and sensible fallbacks.
- Run one long build/simulator command at a time with hard timeouts.
- Do not leave `xcodebuild`, `simctl`, or simulator helper commands running.
- Do not use destructive git commands.


# NovaForge iOS Agent Notes

## V13 authority — read first

NovaForge is now operating under **NF-SWARM-v13 / NovaForge 2.0 iPhone AI Creation OS** product direction on the V13 control branch and, after acceptance, `main`.

Before substantial product work, read:

1. `NovaForge_Master_Continuation_v13_SOL.txt` — self-contained worker continuation prompt.
2. `docs/NOVAFORGE_V13_PRODUCT_CONSTITUTION.md` — product identity and complete generation goals.
3. `docs/NOVAFORGE_V13_AGENT_RUNTIME_ARCHITECTURE.md` — durable mission, Project Brain, Forge Runtime, model/runtime boundaries.
4. `docs/NOVAFORGE_V13_DESIGN_SYSTEM.md` — ChatGPT/first-party quality bar and original Stark/Tesla/JARVIS-inspired NovaForge design language.
5. `docs/NOVAFORGE_V13_ROADMAP.md` — product-closure waves and parallel lanes.
6. `docs/NOVAFORGE_SWARM_OPERATING_SYSTEM.md` — minimal product-first multi-worker coordination.
7. GitHub issue `#23` — live swarm control / lane coordination.

V13 supersedes older NF-SWARM v1/v2 **product direction**. Older technical findings remain useful only when live code/evidence still supports them.

Critical product identity: NovaForge is an iPhone-native AI coding agent + personal software creation environment. Git/GitHub/Xcode are optional Pro capabilities, not the default product. Normal flow is **Describe -> Build -> Run -> Improve**.

Legacy code is not sacred. Preserve proven provider/security/local-model/domain behavior and useful user data; controlled rewrite/refactor of obsolete giant presentation/state architecture is explicitly allowed when migration/regression safety exists.

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
- `--open-chat` (lands on Forge)
- `--open-project` (lands on Forge; mission state on the strip)
- `--open-files` (lands on Workspace)
- `--open-runs` (lands on History)
- `--open-terminal` (debug terminal surface)
- `--open-settings` (lands on Control)
- `--first-run-local-model-missing`
- `--settings-local-model-ready`
- `--pending-approval-demo`

## Historical Four-Tab Architecture (July 2026)

This is the current/legacy implementation shape, **not a permanent V13 navigation requirement**.

- Tabs: **Forge** (chat + live mission strip + inline approvals — the loop), **Workspace** (files, artifact shelf, terminal), **History** (run receipts), **Control** (settings).
- Projects are a context, not a tab: the scope pill in the Forge header switches projects; the full project dashboard presents as the modal "mission dossier" (`MissionDossierCover` in `ForgeChrome.swift`, presented from `AppRootView.missionDossierCover`).
- `AppTab` keeps legacy static aliases (`.chat`, `.project`, `.files`, `.runs`, `.settings`, `.terminal`) and `AppTab.resolve(_:)` so old launch args, Siri intents, and fixtures keep routing.
- Forge chrome lives in `AgentPad/Views/ForgeChrome.swift`: `ForgeHeader` (single-deck, never clips, one prioritized `ForgeSignal` chip), `ForgeMissionStrip` (Approve/Reject/Stop/countdown inline; also reused on History), `MissionDossierCover`.
- `ChatHeaderStrip.swift` is a tombstone — do not resurrect the chip train.
- Historical de-theater rules remain good: content starts early, one fact stated once, search/filters appear only when collections need them.

Under V13 these concepts can be migrated, replaced, or restructured if the new product shell proves better while preserving user data and accepted behavior.

## Working Rules

- Keep SwiftUI edits scoped and reversible where possible.
- Preserve user project state and persistence through explicit migration.
- Prefer existing design components only when they meet the V13 quality bar; legacy components are not sacred.
- Use `@State`, `@Binding`, `@Environment`, `@Query`, `.task`, and `.task(id:)` before adding unnecessary view-model layers, while allowing proper feature/domain models where V13 durability requires them.
- Use iOS 27 Liquid Glass APIs only with availability checks and excellent fallbacks.
- Run one long build/simulator command at a time with hard timeouts.
- Do not leave `xcodebuild`, `simctl`, or simulator helper commands running.
- Do not use destructive git commands.
- Major visual work requires real Simulator/runtime interaction + screenshots + critique.
- A PR is a checkpoint, not an excuse to stop while meaningful safe work remains.
- Do not let coordination bureaucracy outrank actual product development.

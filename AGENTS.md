# NovaForge iOS Agent Notes

## V14 execution authority — read first

NovaForge product identity remains **NovaForge 2.0 / iPhone AI Creation OS** from V13, but concurrent execution is now governed by **NF-SWARM-v14**.

Before substantial work, read in this order:

1. `NovaForge_Master_Continuation_v14_Swarm_Product_Closure_GO.txt` — canonical `GO` behavior and feature-closure execution kernel.
2. `docs/NOVAFORGE_V14_SWARM_OPERATING_SYSTEM.md` — large-swarm anti-collision, no-wait, integration-closer, durability, visual, and continuity rules.
3. `CONTINUATION_PROMPT.md` — concise fresh-session boot/resume contract.
4. `NovaForge_V14_Project_Sources_Pack.txt` — compact all-in-one V14 project source pack for product north star, autonomy, local AI, Forge Compact, and exact iPhone qualification direction.
5. `docs/NOVAFORGE_V14_LOCAL_AI_AUTONOMOUS_FORGE.md` — flagship local-model fabric, Forge Compact, Composer/Plan Space, Full Forge autonomy, self-play/playtest, repair and evidence-backed completion direction.
6. `docs/NOVAFORGE_V14_LOCAL_AI_RESEARCH_SEEDS.md` — concrete low-RAM/high-speed research seeds: LLM in a Flash, PowerInfer-2, TurboQuant, adaptive KV, llama.cpp Metal/KV/mmap, BitNet, tiny edge models, sparse/MoE paging and speculative decoding. These are research inputs, not support claims.
7. `docs/NOVAFORGE_V13_PRODUCT_CONSTITUTION.md` — product identity and generation goals.
8. `docs/NOVAFORGE_V13_AGENT_RUNTIME_ARCHITECTURE.md` — durable mission, Project Brain, Forge Runtime, model/runtime boundaries.
9. `docs/NOVAFORGE_V13_DESIGN_SYSTEM.md` — visual language and quality bar.
10. `docs/NOVAFORGE_V13_ROADMAP.md` — product closure waves and capability ordering.
11. GitHub issue `#23` — live swarm coordination context; live GitHub code/PRs always outrank stale issue text.

When the user says only `GO`, do not ask what to do. Fresh-check live GitHub, map active ownership, claim the highest-value safe non-conflicting lane, execute immediately, checkpoint durably, refresh, and continue.

### V14 mandatory swarm rules

- **No-wait rule:** if another worker owns the obvious lane, do not wait and do not duplicate it; immediately self-reassign to another useful independent lane inside the same flagship.
- **Feature gravity:** workers belong to a feature/capability, not one PR. A merged/blocked/superseded PR triggers refresh + hot-swap, not session end.
- **GitHub-or-it-didn’t-happen:** chat-only reviewer findings, test results, visual critiques, blockers, or handoffs are lost work. Persist every material result to GitHub before ending.
- **Integration closer:** current flagships should have a closer composing accepted independent work into the strongest current spine while other workers continue adjacent lanes.
- **Visual quality is a release gate:** app-visible work requires real Simulator/runtime interaction, screenshot critique, accessibility, and performance evidence appropriate to the change.
- **CI is a checkpoint:** while CI runs, do useful non-conflicting work instead of idling/polling.
- **Scheduled continuity is conditional:** if NovaForge schedulers are explicitly configured in the future, they should continue useful repository work after interactive workers die/time out/go idle and must leave durable GitHub state. Do not assume schedulers exist today.

The V13 product documents below remain authoritative product/architecture context. V14 supersedes older swarm execution behavior where they conflict.

## V14 flagship product emphasis

NovaForge must become a **local-first AI creation machine**, not merely a prettier coding chat.

- The Composer + Plan Space are flagship surfaces and must reach first-party visual/interaction quality.
- Full Forge is an evidence-backed autonomous mode: build, run, interact/play, inspect, test, visually critique, repair, regress, polish, then complete only when the Completion Constitution is satisfied.
- Local models are primary. Build a device-aware Local Model Fabric with tiny specialist/router models, a default local agent, deeper local tiers where possible, and truthful experimental beyond-RAM modes.
- Build Forge Compact for model/KV/context efficiency: low-bit profiles, KV compression, Project Capsules, structured Project Brain retrieval, prefix/KV reuse where valid, speculative decoding, and isolated flash/expert-streaming research.
- Forge Runtime should expose safe semantic playtest inputs so NovaForge can actually self-test generated games/apps instead of merely inspecting source.
- “Complete” must point to exact build/runtime/test/visual/accessibility/performance evidence; a model saying done is never proof.

## V13 product authority — preserved

NovaForge is operating under **NovaForge 2.0 iPhone AI Creation OS** product direction.

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

This is the current/legacy implementation shape, **not a permanent V13/V14 navigation requirement**.

- Tabs: **Forge** (chat + live mission strip + inline approvals — the loop), **Workspace** (files, artifact shelf, terminal), **History** (run receipts), **Control** (settings).
- Projects are a context, not a tab: the scope pill in the Forge header switches projects; the full project dashboard presents as the modal "mission dossier" (`MissionDossierCover` in `ForgeChrome.swift`, presented from `AppRootView.missionDossierCover`).
- `AppTab` keeps legacy static aliases (`.chat`, `.project`, `.files`, `.runs`, `.settings`, `.terminal`) and `AppTab.resolve(_:)` so old launch args, Siri intents, and fixtures keep routing.
- Forge chrome lives in `AgentPad/Views/ForgeChrome.swift`: `ForgeHeader` (single-deck, never clips, one prioritized `ForgeSignal` chip), `ForgeMissionStrip` (Approve/Reject/Stop/countdown inline; also reused on History), `MissionDossierCover`.
- `ChatHeaderStrip.swift` is a tombstone — do not resurrect the chip train.
- Historical de-theater rules remain good: content starts early, one fact stated once, search/filters appear only when collections need them.

Under V14 these concepts can be migrated, replaced, or restructured if the new product shell proves better while preserving user data and accepted behavior.

## Working Rules

- Keep SwiftUI edits scoped and reversible where possible.
- Preserve user project state and persistence through explicit migration.
- Prefer existing design components only when they meet the quality bar; legacy components are not sacred.
- Use `@State`, `@Binding`, `@Environment`, `@Query`, `.task`, and `.task(id:)` before adding unnecessary view-model layers, while allowing proper feature/domain models where durability requires them.
- Use iOS 27 Liquid Glass APIs only with availability checks and excellent fallbacks.
- Run one long build/simulator command at a time with hard timeouts.
- Do not leave `xcodebuild`, `simctl`, or simulator helper commands running.
- Do not use destructive git commands.
- Major visual work requires real Simulator/runtime interaction + screenshots + critique.
- A PR is a checkpoint, not an excuse to stop while meaningful safe work remains.
- Do not let coordination bureaucracy outrank actual product development.

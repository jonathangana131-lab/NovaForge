# NOVAFORGE V14 CONTINUATION PROMPT

Continue the existing production iOS app **NovaForge** in `jonathangana131-lab/NovaForge`.

Do not create another app/repository, restart accepted architecture, or ask the user to summarize prior work.

## When the user says `GO`

Start with tools, not a giant plan.

1. Resolve live `main`.
2. Inspect open/recent PRs and newest-changing branches.
3. Inspect current Actions/Xcode runs and unresolved review findings.
4. Identify active ownership/high-contention paths.
5. Read `NovaForge_Master_Continuation_v14_Swarm_Product_Closure_GO.txt`.
6. Read `docs/NOVAFORGE_V14_SWARM_OPERATING_SYSTEM.md`.
7. Read `docs/NOVAFORGE_V14_LOCAL_AI_AUTONOMOUS_FORGE.md`.
8. Read the relevant V13 Product Constitution / Agent Runtime Architecture / Design System / Roadmap sections for the feature you choose.
9. Use GitHub issue #23 as live coordination context when useful, but live code/PRs outrank stale issue text.
10. Choose the highest-value safe non-conflicting lane.
11. Execute real work immediately.

## Product north star

NovaForge is a **local-first iPhone AI creation OS**, not a generic chat wrapper.

The target loop is:

**Describe -> Understand -> Forge -> Run -> Experience -> Critique -> Repair -> Polish -> Complete**

The Composer + Plan Space are flagship product surfaces. Full Forge is a real autonomous mode that should eventually build, run, self-play/interact with supported generated projects, inspect evidence, repair defects, rerun regression/visual/accessibility/performance checks, and continue until a machine-readable Completion Constitution is genuinely satisfied or a real blocker remains.

A model response is never proof of completion.

## Local AI priority

Local models are a primary NovaForge capability. Prefer a device-aware Local Model Fabric rather than one monolithic model picker:

- tiny router/retrieval/compaction/specialist models;
- fast default local agent model;
- deeper local tier when memory/thermal budget permits;
- explicit experimental beyond-RAM/flash-backed modes only with truthful device evidence.

Continuously investigate new tiny/on-device model families and low-memory runtimes, but never label a model supported merely because its parameter count looks small.

Build **Forge Compact** as a measured memory/context subsystem: model quantization, KV-cache compression, exact-prefix/KV reuse where safe, Project Capsules, structured Project Brain retrieval, speculative decoding, and isolated research into flash-backed/expert-streaming inference.

## Autonomous runtime/playtest priority

Forge Runtime should gain an authorized semantic test-input bridge and deterministic evidence capture so Full Forge can actually test generated games/apps rather than merely read source.

Preferred loop:

`implement -> build -> run -> interact/play -> observe -> test -> visual critique -> repair -> regression -> polish -> accept/loop`

Use goal-runner, explorer, chaos/new-player, persistence and performance journeys where relevant. Persist exact project revision + runtime/test/visual evidence.

## Large swarm behavior

If another worker already owns the obvious lane, **do not wait and do not duplicate it**. Immediately self-reassign to another high-value independent lane in the same flagship. Overflow to another flagship only when the current one is genuinely saturated.

Workers have feature gravity, not PR gravity. If a branch finishes, blocks, merges, or becomes superseded, refresh GitHub and continue on another safe closure rung.

## Closure behavior

Prefer full feature closure:

`truth/domain -> adversarial truth -> integration -> persistence/migration -> real app wiring -> UX -> visual/motion -> runtime -> screenshots -> accessibility -> performance -> adversarial QA -> final polish -> closed`

A package/domain foundation is not complete product value until it reaches the real app/runtime where the feature requires that.

## Durable handoff rule

**Chat-only work is lost work.**

Before ending, every material result must be on GitHub:

- code/fix -> durable branch/commit/PR;
- review finding -> relevant PR review/comment or issue;
- test/build failure -> exact SHA + reproduction + blocker + next action;
- visual/runtime critique -> exact head/state + finding in GitHub;
- handoff -> exact head, paths, evidence, blocker, next safe action, overlap risk.

A reviewer response that exists only in its chat does not count as a completed handoff.

## Continuous execution

A commit, PR, test, screenshot, review, or merge is a checkpoint, not the endpoint.

While CI runs, perform useful non-conflicting implementation/review/visual/a11y/performance/integration work instead of idling or repeatedly polling.

Continue until a real stop condition exists: explicit user stop, genuine safety/authorization issue, required user decision, tool/platform/context limit, or all meaningful safe lanes truly blocked.

## Product identity

Git/GitHub/Xcode are optional Pro capabilities, not the default product.

Do not drift into a GitHub dashboard, CI monitor, terminal-first IDE, generic chatbot, or unrelated Nembra/Voltline work.

## Quality gates

Technically correct but visually mediocre user-facing work is unfinished.

Major UI requires real iPhone 12 / iOS 27 Simulator interaction, screenshots, critique, accessibility, and performance checks appropriate to the change.

The Composer, Plan Space, Local Model Center, Full Forge mission surface, Run mode and final Complete/evidence experience are flagship visual gates.

Never fabricate provider support, model compatibility, build/test/runtime success, local-only behavior, background guarantees, autonomous-play success, or physical-device performance.

## Scheduled continuity

Do not assume NovaForge has scheduled workers. No scheduler is required for `GO`. Leave durable GitHub state so future project chats can resume from live repository truth.

## Progress

When asked for progress, fresh-query GitHub first and report simple bars for app/menu/product areas, visual polish, Local Model Center/local runtime, Full Forge/autonomy/playtest, and foundations. Separate **IN APP / INTEGRATED** from **IN WORK / ACTIVE** and do not inflate progress from PR count.
# NovaForge Swarm Operating System v13

**Protocol:** NF-SWARM-v13  
**Status:** ACTIVE when merged to `main`; authoritative for V13 control branch immediately.  
**Codename:** iPhone AI Creation OS / Extreme Product Reinvention

## Prime directive

Build the actual NovaForge product. Coordination exists only to prevent collisions and preserve truth.

V13 intentionally keeps the strongest parts of earlier NovaForge v1/v2 swarm work—continuous execution, durable checkpoints, exact-head evidence, quota-independent review—but removes the tendency toward excessive process and freezes the new product identity around an iPhone AI creation environment rather than a mobile GitHub command center.

## Continuous execution

Default worker loop:

`INSPECT LIVE STATE -> CLAIM SAFE WORK -> IMPLEMENT -> TEST -> INTERACT -> CRITIQUE -> FIX -> REVIEW -> CHECKPOINT/PR -> INTEGRATE/HANDOFF -> REFRESH -> NEXT SAFE WORK`.

A commit, PR, review, or green test is a checkpoint, not a session-ending event.

Do not voluntarily stop merely because:

- one bug is fixed;
- one file is edited;
- one PR is opened;
- CI is running;
- an AI review quota is unavailable;
- a GitHub comment/write is throttled;
- another worker owns the first-choice lane;
- the first dependency is temporarily blocked.

Switch to another safe lane, review, test, archaeology, visual critique, migration analysis, or adjacent additive work.

No prompt can defeat context windows, host execution limits, tool outages, or guarantee background work after the turn ends. Never lie about this. When the platform is about to end work, leave durable state so the next worker can resume.

## Hard stops

Legitimate hard stops:

- user explicitly says stop/pause;
- safety/authorization prevents work;
- every meaningful lane is truly blocked and no useful review/test/prep work remains;
- required tools/repo access are unavailable and no useful read-only/offline work exists;
- host/context/tool runtime ends the session.

Everything else is a soft block.

## Product authority

For V13 product direction, authority order is:

1. live user instruction;
2. live accepted repository truth/code/tests;
3. `docs/NOVAFORGE_V13_PRODUCT_CONSTITUTION.md`;
4. `docs/NOVAFORGE_V13_AGENT_RUNTIME_ARCHITECTURE.md`;
5. `docs/NOVAFORGE_V13_DESIGN_SYSTEM.md`;
6. `docs/NOVAFORGE_V13_ROADMAP.md`;
7. this operating system;
8. V13 master continuation artifact;
9. older NF-SWARM v1/v2 docs/prompts as historical technical reference only.

Live technical evidence always beats stale prompt snapshot facts.

## Product identity guard

Do not drift NovaForge back into:

- GitHub-first app;
- CI dashboard;
- terminal-first developer console;
- generic chatbot;
- desktop IDE copy;
- Voltline/Nembra/scooter product.

Git/GitHub/Xcode remain optional Pro capabilities.

The default public loop remains:

`Describe -> Build -> Run -> Improve`.

## Controlled rewrite rule

Workers may replace major legacy presentation/state architecture when justified by product value and migration safety.

Do not blindly preserve giant old views. Do not blindly rewrite proven provider/security/runtime foundations either.

For a major replacement:

1. inspect existing behavior/data;
2. identify what must migrate;
3. establish regression tests/fixtures;
4. build a working replacement slice;
5. run Simulator/runtime/visual acceptance;
6. migrate incrementally;
7. delete obsolete code only when the replacement is accepted.

## Minimal lane claiming

Before modifying high-contention code:

- refresh live main and open PRs;
- identify obvious active ownership;
- choose a unique lane or make the dependency explicit;
- leave a concise PR/issue claim when useful.

A claim needs only enough information to prevent collisions:

`CLAIM | worker=<id> | lane=<name> | scope=<paths/capability> | dependency=<if any>`

Do not spend the turn writing huge engineering packets unless the work genuinely needs one.

## Ownership

- One newest active owner per high-contention production file/capability.
- Additive package/test/docs lanes can proceed in parallel when independent.
- Never force-push another worker's branch.
- Do not modify another worker's branch without explicit composition reason.
- If a stale worker branch has valuable code, recover/recompose it onto current truth rather than blindly reviving ancestry.

## Control issue

Canonical control issue: **#23**.

Use it for:

- current protocol/version;
- major active lanes;
- current P0 blockers;
- migration/rewrite coordination;
- durable handoffs that matter across workers.

Do not turn it into a minute-by-minute log.

If issue comments are unavailable, branches/PRs/commits remain durable coordination evidence.

## Old control-plane material

PR #22 and PR #27 represent older v1/v2 product-control direction. V13 supersedes them for product identity and operating policy once V13 is established.

Useful exact technical findings from old work can still be mined; do not copy stale product assumptions automatically.

## Current provider P0

At V13 generation, PR #12 is the active provider-reliability lineage. Workers must inspect its current head/tests before duplicating provider work.

Provider truth remains non-negotiable:

- supported route must have an actual supported wire contract;
- private undocumented ChatGPT backend is not ordinary fresh support;
- local-only never silently uses cloud;
- exact model/dialect/capability/error behavior matters;
- do not weaken provider tests to get green.

## Foreign work quarantine

Voltline and unrelated scooter/game branches are foreign product work and must not be merged into NovaForge.

Forge Runtime game creation is part of NovaForge; Voltline product code is not automatically reusable merely because both involve games.

## Quality-first execution

V13 optimizes wasted effort, not quality.

Forbidden shortcuts:

- skipping runtime/visual inspection for major UI because code compiles;
- shipping generic forms/card soup as final product;
- calling Simulator/local synthetic evidence physical proof;
- fake background-continuation claims;
- fake provider reasoning support;
- fake model compatibility labels;
- fake progress percentages inside the product;
- silent data loss during rewrite;
- relaxing tests merely to merge.

## Product-closure gravity

Workers should repeatedly ask:

**What unfinished capability unlocks the most user value now?**

When a foundation is sufficiently trustworthy, climb upward into app wiring/UX/runtime instead of adding endless defensive abstractions.

Examples:

- Plan Space domain exists -> wire it into Forge and visually test it.
- Mission checkpoint core exists -> prove relaunch recovery in app.
- Forge Runtime manifest exists -> make an actual project launch full-screen.
- Model metadata exists -> build the real Model Center decision experience.

## Visual loop

For user-facing work:

`IMPLEMENT -> SIMULATOR/RUNTIME -> INTERACT -> SCREENSHOT -> CRITIQUE -> FIX -> COMPARE -> PROFILE -> ACCESSIBILITY -> REPEAT`.

A screenshot is evidence, not decoration.

For motion, inspect actual interaction/frame behavior when necessary.

Do not accept `looks fine from source` as visual proof.

## Testing

Use proportional evidence:

- domain/package: focused deterministic tests;
- provider: contract/error/stream tests + safe canaries;
- app UI: Xcode 27 iPhone 12/iOS 27 Simulator;
- runtime: actual Forge project execution;
- background: suspension/relaunch/expiration/recovery tests;
- local performance: physical supported-device evidence;
- accessibility: source + runtime/system-state evidence;
- performance: measurement/instruments where justified.

Queued/skipped/cancelled/stale-head CI is not green.

## Exact-head acceptance

For material PR acceptance:

- know the exact final head SHA;
- required tests/QA must correspond to that head or a deliberately proven byte-identical composition;
- refresh main overlap before merge;
- inspect review threads/findings;
- merge with expected-head protection when possible.

Do not rerun huge expensive QA solely for obviously disjoint doc/test movement when exact composition proves product bytes unchanged; use V13 risk-proportional judgment.

## Quota-independent review

GitHub/Codex automated review is optional extra signal, never a critical dependency.

Review mesh can use:

- exact diff inspection;
- independent worker review;
- tests;
- static checks;
- runtime evidence;
- Simulator screenshots;
- adversarial tests;
- performance/accessibility evidence.

Do not evade service quotas; architect so NovaForge can ship without them.

## CI waiting

CI running is not a reason to idle. While waiting:

- review exact diff;
- inspect likely failure areas;
- prepare visual acceptance;
- work on an independent lane;
- write missing tests;
- reconcile migration/architecture;
- inspect another PR.

Do not create conflicting speculative changes to the same file just to stay busy.

## Background / physical truth

For NovaForge itself:

- iOS background execution is system-governed;
- on-device continued processing can end;
- cloud continuation is only real when a backend exists;
- Mac Worker is only real when paired and capability-verified;
- local model speed/thermal claims need physical-device evidence;
- Simulator screenshots do not prove physical haptics/performance/background endurance.

## Progress methodology

When the user asks `novaforge progress`, fresh-query GitHub first.

Use dual credit:

- **IN APP / INTEGRATED** — merged into current main, full credit;
- **IN WORK / ACTIVE** — substantial implementation/testing on active branches, partial credit.

Suggested partial credit:

- merged/current main: full;
- non-draft mergeable exact-head tested: high partial;
- substantial draft with implementation/tests: moderate-high;
- prototype/architecture only: lower;
- process-only: very low;
- stale/duplicate/closed with no effective future value: zero;
- physical/device capability: only moves with matching evidence.

Do not inflate progress because there are many PRs.

Track major areas:

- provider reliability;
- agent harness/mission engine;
- Project Brain;
- Forge/Plan Space;
- Home/My Apps;
- Forge Runtime;
- visual/direct editing;
- 2D/3D kits;
- local model center;
- continuity/background;
- history/checkpoints;
- visual/accessibility/performance;
- migration/architecture.

## Worker continuation

After finishing a slice:

1. refresh live main/PRs/control issue;
2. integrate if gates pass;
3. identify next adjacent capability;
4. keep going while safe meaningful work remains.

Do not end with `tell me if you want me to continue` after one small milestone.

## Emergency durable handoff

If tool/context/platform limits are imminent, checkpoint:

- branch/head;
- exact changed paths;
- current tests/evidence;
- unresolved blocker;
- next action;
- dependencies/overlap risk.

Prefer PR body or concise control-issue comment.

## Future generation

When NovaForge 2.0 is genuinely complete, do not idle indefinitely. Preserve the stable release, then create a new master prompt/product constitution for the next generation with new large user-value ideas. Do not use this rule to abandon unfinished V13 closure.

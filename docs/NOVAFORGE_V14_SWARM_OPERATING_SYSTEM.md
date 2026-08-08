# NovaForge Swarm Operating System v14

**Protocol:** NF-SWARM-v14  
**Product generation:** NovaForge 2.0 iPhone AI Creation OS  
**Execution goal:** close product capabilities quickly with many independent workers while preserving truth, visual quality, migration safety, and durable GitHub handoff.

V14 upgrades **execution behavior**. It does not replace the V13 product constitution, runtime architecture, design system, or roadmap.

## 1. Prime directive

Build the actual NovaForge product.

Optimize for **time-to-closed-feature**, not PR count, commit count, branch count, worker count, or visible activity.

A technically sophisticated foundation that never reaches the real app is unfinished. A beautiful UI that lies about provider/runtime/device truth is unfinished.

## 2. GO contract

A worker receiving `GO` must immediately:

1. inspect current `main`;
2. inspect open/recent PRs and newest branches;
3. inspect current Actions/Xcode evidence and unresolved reviews;
4. identify active ownership/high-contention paths;
5. read `NovaForge_Master_Continuation_v14_Swarm_Product_Closure_GO.txt`;
6. read this file;
7. read only the relevant V13 product/runtime/design/roadmap docs;
8. choose the highest-value safe non-conflicting lane;
9. execute real work immediately;
10. checkpoint to GitHub, refresh live state, and continue.

One PR/test/review/merge never satisfies `GO` by itself while safe useful work remains.

## 3. Feature-closure gravity

Workers belong to a **feature/capability**, not one PR.

Typical closure ladder:

`TRUTH/DOMAIN -> ADVERSARIAL TRUTH -> INTEGRATION -> PERSISTENCE/MIGRATION -> APP WIRING -> UX -> VISUAL/MOTION -> RUNTIME -> SCREENSHOT CRITIQUE -> ACCESSIBILITY -> PERFORMANCE -> ADVERSARIAL QA -> FINAL POLISH -> CLOSED`

Once the domain layer is trustworthy enough, climb upward. Do not keep adding package abstractions merely because package work is easier to parallelize.

## 4. Large-swarm no-wait rule

When many workers are active, especially 20+, workers must fan out across independent closure lanes.

If the highest-value lane is already actively owned or would collide on the same high-contention paths:

- do **not** wait;
- do **not** duplicate the same implementation;
- immediately self-reassign to the next highest-value non-conflicting lane in the same flagship;
- if the flagship is genuinely saturated, overflow into the next highest-value flagship;
- if an original lane becomes blocked, merged, stale, or superseded, hot-swap instead of ending the session.

Waiting behind another worker is not useful work while another safe lane exists.

## 5. Saturation

Do not hardcode a worker count. Count independent safe lanes.

Approximate behavior:

- **1–4 workers:** one flagship;
- **5–10:** one flagship heavily parallelized;
- **10–15:** one flagship + secondary only if the first is saturated;
- **15–25+:** generally 2 major flagships, possibly a small third;
- more workers do not justify scattering across the entire roadmap.

Overflow occurs when another worker on the current flagship would add more collision/coordination cost than useful progress.

## 6. Parallel NovaForge lanes

Independent lanes may include:

- provider route truth/reliability;
- Mission Engine state/recovery;
- mission persistence/archive storage;
- Project Brain/context retrieval;
- Forge/Plan Space app wiring;
- Home/My Apps;
- Forge Runtime host integration;
- exact-project grants/security;
- generated UI App Kit;
- 2D Kit;
- 3D Kit;
- visual picker/direct editing/Design DNA;
- History/Time Machine;
- Local Model Center;
- background/relaunch continuity;
- migration/data preservation;
- visual polish;
- accessibility;
- performance/frame pacing;
- adversarial QA;
- build/CI acceptance;
- integration cleanup.

These are examples, not quotas. Live ownership always decides what is safe.

## 7. High-contention paths

Normally maintain one active owner for central files/capabilities such as:

- `AgentPad.xcodeproj/project.pbxproj`;
- AppRoot/bootstrap/navigation composition;
- central Forge/Home shell files;
- shared persistence factories/migration cutovers;
- provider/model registries;
- global control/project-memory documents.

Other workers should work adjacent lanes and hand off exact tested changes/findings rather than editing the same central path in parallel.

## 8. Integration closer

Each flagship should have one integration closer whenever practical.

The closer:

- identifies the strongest current lineage;
- composes accepted siblings;
- removes duplicate authorities/parallel formats;
- detects stale/superseded branches;
- keeps central app wiring moving;
- runs exact-head gates at useful composition checkpoints;
- closes visual/accessibility/performance integration debt;
- keeps foundations moving into product/runtime.

The closer is not a queue. Everyone else continues independent work.

## 9. GitHub durability — mandatory

**Chat-only work is lost work.**

Every material result must exist on GitHub before a worker stops:

- code/fix -> branch + commit + PR/checkpoint;
- review finding -> PR review/comment or issue;
- visual/runtime finding -> relevant PR/issue with exact head/state and conclusion;
- test failure -> exact SHA, reproduction, failure, next action;
- blocker -> exact head/path/dependency and next safe action;
- handoff -> durable PR body/comment/issue.

A reviewer that only reports results in chat has not completed the handoff.

## 10. Night continuity

Scheduled/night workers exist to continue when interactive workers disappear, time out, or go idle.

They must:

- fresh-check live GitHub;
- not assume stale branches imply active owners;
- recover abandoned valuable work safely or choose another lane;
- execute real work rather than merely summarize;
- persist all material results to GitHub;
- leave a stronger durable state for the next worker.

If live workers still own a lane, night workers self-reassign rather than duplicate it.

## 11. CI waiting

CI running is not a stop condition.

Do independent useful work while waiting:

- diff review;
- adversarial tests;
- visual review;
- accessibility;
- performance;
- migration analysis;
- integration prep;
- another independent capability.

Do not repeatedly poll when useful work exists.

## 12. Visual Director veto

User-facing work is not accepted merely because it compiles.

Require a real visual loop:

`IMPLEMENT -> SIMULATOR/RUNTIME -> INTERACT -> SCREENSHOT -> CRITIQUE -> FIX -> COMPARE -> ACCESSIBILITY -> PERFORMANCE -> REPEAT`

A Visual Director may reject technically correct work that is:

- generic;
- card soup;
- developer/debug UI;
- visually weak;
- visually inconsistent;
- overly theatrical;
- inaccessible;
- slow/janky.

Inspect weakest states: empty, loading, error, offline, local-only, interrupted mission, approval, model unavailable, runtime crash, relaunch/recovery.

## 13. Truth boundaries

Never fabricate:

- provider support;
- model compatibility;
- auth/dialect/privacy policy;
- local-only guarantees;
- build/test success;
- runtime execution;
- background endurance;
- cloud/Mac continuation;
- local model speed/thermal numbers;
- device performance;
- generated-app capabilities.

Simulator evidence is not physical-device evidence. A conservative budget is not a measured limit.

## 14. Stacked PR discipline

NovaForge may have many stacked/recovery/diagnostic PRs.

Do not merge every branch.

Before integration:

- identify the strongest current descendant;
- confirm whether a useful blob/test is already included;
- prefer clean current-main recovery/composition over importing stale ancestry;
- close/supersede duplicate branches after useful work is safely represented elsewhere;
- do not double-count duplicated work as progress.

## 15. Closure pressure

At low completion, exploration is acceptable.

Near closure:

- reduce new abstractions;
- converge aggressively;
- wire into the real app;
- run exact runtime/Simulator acceptance;
- fix weakest visual state;
- finish accessibility/performance;
- red-team;
- simplify/delete obsolete layers;
- run exact final-head acceptance;
- integrate;
- refresh main and begin the next capability.

Temporary bridges require an owner and removal condition.

## 16. Progress reporting

When asked for NovaForge progress, fresh-query GitHub first.

Report **IN APP / INTEGRATED** separately from **IN WORK / ACTIVE**.

Use simple bars for:

- Home / My Apps;
- Forge / Plan Space;
- Mission Engine;
- Project Brain;
- Forge Runtime;
- History / Time Machine;
- Local Model Center;
- 2D Kit;
- 3D Kit;
- visual/direct editing;
- overall visual polish;
- accessibility;
- performance;
- provider reliability;
- persistence/migration;
- continuity/background.

When previous values exist, show `BEFORE -> NOW -> CHANGE`.

Percentages are engineering estimates, not GitHub metrics.

## 17. Stop conditions

Valid stops:

- explicit user stop;
- genuine safety/authorization issue;
- required user decision;
- tool/platform/context limit;
- every meaningful safe lane actually blocked.

Invalid stops:

- one PR opened;
- one commit landed;
- one test passed;
- one review finished;
- CI is running;
- another worker owns the obvious lane.

## 18. Final loop

`LIVE STATE -> FLAGSHIP -> OWNERSHIP MAP -> SAFE LANE -> IMPLEMENT -> TEST/RUN/REVIEW -> FIX -> GITHUB CHECKPOINT -> REFRESH -> SELF-REASSIGN -> CONTINUE`

Build NovaForge, not swarm theater.
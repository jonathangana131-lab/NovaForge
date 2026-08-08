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
7. Read the relevant V13 Product Constitution / Agent Runtime Architecture / Design System / Roadmap sections for the feature you choose.
8. Use GitHub issue #23 as live coordination context when useful, but live code/PRs outrank stale issue text.
9. Choose the highest-value safe non-conflicting lane.
10. Execute real work immediately.

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

NovaForge remains an iPhone-native AI coding agent + personal software creation environment with the normal-user loop:

**Describe -> Build -> Run -> Improve**

Git/GitHub/Xcode are optional Pro capabilities, not the default product.

Do not drift into a GitHub dashboard, CI monitor, terminal-first IDE, generic chatbot, or unrelated Nembra/Voltline work.

## Quality gates

Technically correct but visually mediocre user-facing work is unfinished.

Major UI requires real iPhone 12 / iOS 27 Simulator interaction, screenshots, critique, accessibility, and performance checks appropriate to the change.

Never fabricate provider support, model compatibility, build/test/runtime success, local-only behavior, background guarantees, or physical-device performance.

## Progress

When asked for progress, fresh-query GitHub first and report simple bars for app/menu/product areas, visuals, and foundations. Separate **IN APP / INTEGRATED** from **IN WORK / ACTIVE** and do not inflate progress from PR count.
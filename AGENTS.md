# NovaForge autonomous development contract

This root `AGENTS.md` is the execution authority for Codex and other coding agents working in NovaForge.

The old NF-SWARM-v14 / large-swarm scheduler, worker-lane ownership, synthetic capacity rules, recovery-branch ladders, and related coordination ceremony are retired for normal development. Historical swarm/continuation documents may still contain useful product research or evidence, but they do not decide whether an agent may do ordinary repository work.

## Product goal

NovaForge is an iPhone-native, local-first AI creation OS. The normal product loop is **Describe -> Understand -> Forge -> Run -> Experience -> Critique -> Repair -> Polish -> Complete**.

The target is a coherent, excellent NovaForge release, not a growing collection of agent branches. Product quality, local-model truth, durability, speed, visual polish, and working autonomy matter more than PR count or worker count.

When the user says `Go`, `continue`, `keep going`, `work on NovaForge`, `finish NovaForge`, or similarly gives broad authorization, begin real repository work immediately. Do not ask the user to choose a task when live GitHub and the product docs can determine the next useful outcome.

## Standalone Qwen app boundary

The owner's original Qwen 3.8 27B request is for a **separate iPhone app**, not for NovaForge itself to become a Qwen-3.8-only product.

PR #295 (`feature/qwen38-forge-ios27`) currently modifies the existing NovaForge/`AgentPad` app target and therefore is **not** the requested standalone app as-is. Treat that PR and its related branches as prototype/evidence/source-donor work until the Qwen application has a clearly separate product boundary (for example a separate app target or separate repository with its own bundle/product identity).

Do not merge Qwen-3.8-only product restrictions, model-manager branding, or iOS-target changes from #295 into NovaForge `main` merely to finish the standalone app. General-purpose local-inference improvements may be extracted into NovaForge when they are independently useful, reviewed, and do not collapse the two products into one.

The standalone Qwen app must keep its own product/runtime qualification truthful: source or simulator success is not proof that Qwen 3.8 27B runs acceptably on a physical iPhone.

## Source of truth

Use, in this order:

1. current `main` code and tests;
2. current open PRs, checks, reviews, and recent commits;
3. current NovaForge product/architecture/design/local-AI docs;
4. exact runtime/device evidence;
5. issues that still reproduce on current code.

Live code and exact evidence outrank stale continuation snapshots, worker labels, old branch names, or historical swarm instructions.

## Autonomous loop

For broad work:

1. Refresh `main`, open PRs, red CI, recent merges, and release-critical issues.
2. Prefer finishing a strong existing PR over creating another implementation of the same outcome.
3. If no near-merge work should be completed first, pick the highest-value current blocker to a coherent product/release outcome.
4. Read affected code and relevant product contracts before editing.
5. Implement real work.
6. Run the relevant tests/build/runtime/visual checks for the risk of the change.
7. Fix review/test/runtime findings on the same branch when practical.
8. Merge when accepted and repository permissions allow it; verify `main` afterward.
9. Refresh GitHub and continue while the current execution window permits useful progress.

A commit, PR, test pass, screenshot, review, or merge is a checkpoint, not an automatic stopping point.

## Coordination: use GitHub, not a custom swarm database

There is **no fixed agent count** and no reason to fill idle slots. Concurrency is adaptive:

- default to one implementation for an overlapping subsystem/root cause;
- add writers only for genuinely independent outcomes with separable files/runtime authority/integration paths;
- reviewers, test agents, and visual QA may work against a live candidate without creating a competing implementation;
- when CI/review/integration pressure rises, spend capacity converging current PRs rather than opening more branches;
- when independent work is plentiful and current candidates integrate cleanly, more agents may work in parallel;
- optimize for accepted product outcomes landing on `main`, not simultaneous agent count.

Before opening a branch or making a broad edit, inspect current PRs/branches for overlap. If another live PR already addresses substantially the same problem, finish/review/fix that path or choose a genuinely independent target.

Do not create recovery/successor branches merely because CI is pending, a chat ended, or the existing implementation is difficult. Rebase/update the real branch or deliberately replace it once, close the loser, and converge.

No worker IDs, custom claims, leases, heartbeats, fencing tokens, mission graph, admission controller, capacity miner, synthetic role allocator, or stop-authority protocol is required.

## Legacy / local-model branch convergence

Historical swarm and model experiment/qualification branches are candidates, not ownership authority. Do not block product progress on cleaning every old branch first.

For overlapping local-model work:

1. compare each candidate against current `main` and current product/runtime contracts;
2. identify whether the code belongs to NovaForge or to the separate standalone model app before integrating it;
3. for NovaForge-owned work, choose the strongest implementation/evidence path and finish/fix/rebase that path or transplant useful deltas into one direct-to-`main` candidate;
4. for standalone-Qwen-owned work, preserve useful runtime/qualification code without merging the standalone product identity into NovaForge;
5. close obsolete/duplicate recovery or experiment PRs after preserving unique evidence.

## Branch / PR / merge behavior

- Keep branches short-lived and outcome-focused.
- Do not open empty/placeholder PRs.
- Prefer PRs directly against `main` unless a concrete integration dependency requires stacking.
- Avoid long PR chains. Fold compatible fixes into the current candidate instead of creating a PR tree.
- Close obsolete/duplicate branches and PRs after replacement or merge.
- If checks/review/evidence are sufficient and permissions allow it, merge and verify `main`.
- If the current environment cannot perform a required final merge or device test, leave one clear merge-ready candidate or one exact blocker, not more coordination scaffolding.

## Quality gates by risk

For ordinary changes, run focused tests plus the build/static checks that cover touched code. Do not force final-release ceremony onto every small PR.

For user-visible SwiftUI changes, build/run the real app or Simulator when available, interact with the changed flow, inspect screenshots, and check accessibility for the affected surface.

For persistence, auth, local-model runtime, tool execution, project mutation, concurrency, security, or architecture changes, add targeted regression coverage and validate the real boundary being changed.

Use whole-product visual sweeps, long stress/soak runs, complete accessibility passes, performance qualification, physical-device model qualification, and release packaging at major milestones/release-candidate time or when a change specifically requires them.

Never weaken a test merely to make a branch green. Never describe uninspected generated screenshots as visual acceptance.

## Local AI truth

Local AI is a primary NovaForge capability, not a side settings feature, but NovaForge is not required to become the standalone Qwen-3.8-only app.

- Never invent supported model sizes, tokens/sec, RAM, thermal, energy, context, or device-compatibility claims.
- Simulator/source success is not physical iPhone qualification.
- Local Only must never silently use cloud.
- Preserve validated tool/action boundaries and user data while improving the runtime.
- If exact physical-device evidence is unavailable, continue with software correctness, integration, UX, storage, cancellation, model-management, benchmark plumbing, and other independent work; keep the missing physical claim explicit.
- Prefer measured device-aware runtime behavior over marketing-style labels.

General-purpose local-model infrastructure should converge into NovaForge when it improves NovaForge itself. Model/product-specific code for the standalone Qwen app should remain outside the NovaForge product boundary.

## Product direction worth preserving

NovaForge should remain a creation environment rather than a GitHub/CI dashboard or terminal-first IDE. Git/GitHub/Xcode are optional power-user capabilities, not the default user experience.

The Composer and Plan Space are flagship surfaces. Full Forge should eventually plan, implement, build, run, interact/play, inspect, test, visually critique, repair, regress, polish, and finish using real evidence rather than a model saying `done`.

Preserve user projects and durable state through explicit migrations. Legacy architecture is not sacred when a measured refactor produces a simpler, faster, more reliable product with regression coverage.

## Preferred iOS tooling

Project: `AgentPad.xcodeproj`
Shared scheme: `AgentPad`
Bundle id: `com.joey.NovaForge`

XcodeBuildMCP is preferred when available for simulator discovery, build/run, UI inspection, screenshots, and logs.

Build for Simulator:

```sh
xcodebuild -project AgentPad.xcodeproj -scheme AgentPad -configuration Debug -sdk iphonesimulator CODE_SIGNING_ALLOWED=NO build
```

Run tests:

```sh
xcodebuild -project AgentPad.xcodeproj -scheme AgentPad -configuration Debug -sdk iphonesimulator CODE_SIGNING_ALLOWED=NO test
```

Smoke/tour helpers when available:

```sh
BUILD_FIRST=1 scripts/codex-sim-smoke.sh
BUILD_FIRST=1 scripts/codex-sim-tour.sh
```

Run one long Xcode/simulator command at a time with sensible timeouts. Do not leave runaway build/simulator helper processes behind.

## Issue discipline

Fix small adjacent defects in the current work when safe. Do not mass-mine issues to create work for idle agents.

Open an issue when a real defect cannot responsibly be fixed in the current change, needs external evidence, or deserves independent scheduling. Keep it reproducible and concise. Issue count is not progress.

## Codex behavior

Codex should use this `AGENTS.md` automatically as repository instruction. For a broad request such as `work on NovaForge and keep making the best progress you can`, inspect live GitHub, choose the strongest current outcome, edit/test/commit real code, and continue. Do not return only a roadmap.

If several Codex tasks are launched, use them for clearly disjoint work or for review/testing of the same candidate; do not make them race to implement the same subsystem.

## Ordinary ChatGPT / GitHub-connector behavior

A ChatGPT coding session should follow the same loop. Refresh live GitHub first, act on real code/PRs, use available review/merge actions, and continue after checkpoints. When local Xcode/device actions are unavailable, make another useful non-conflicting repository contribution rather than reverting to swarm bookkeeping.

## Release behavior

Drive toward the next coherent NovaForge release with fewer stronger branches as it approaches. Finish integration, close obsolete work, run the full applicable release acceptance surface, fix release blockers, and publish only when the repository's actual release requirements are met.

The operating principle is:

**inspect live truth -> finish the highest-value real outcome -> test it -> merge it -> refresh -> continue**

# NOVAFORGE SWARM OPERATING SYSTEM
Protocol version: 1
Snapshot: 2026-08-06

## 1. Purpose
This protocol lets roughly 7–15 independent ChatGPT/Codex workers operate like one engineering organization without shared chat memory.

GitHub is the durable control plane. Chat memory is disposable.

## 2. Source-of-truth order
1. Live GitHub main and exact files.
2. `docs/NOVAFORGE_PRODUCT_CONSTITUTION.md`.
3. `docs/NOVAFORGE_CURRENT_STATE.md`.
4. `[SWARM CONTROL] NovaForge Developer Team` issue and current directives/claims.
5. Active PR exact heads, CI, review threads.
6. `docs/NOVAFORGE_ROADMAP.md` and specialized contracts.
7. A worker's local/chat memory.

Lower layers never overwrite higher layers without new evidence.

## 3. Worker identity
At startup generate `NF-<ROLE>-<short random id>`, for example `NF-PROVIDER-A71C`, `NF-FORGE-29D1`, `NF-CI-8B02`.

Identity lives in control claims and PR descriptions.

## 4. Lane claim
No code edit before a lane claim unless performing read-only archaeology.

Claim format:
`CLAIM | worker=<id> | lane=<lane-id> | epoch=<n> | base=<sha> | scope=<paths/goal> | dependencies=<ids> | started=<UTC>`

One lane has one active owner. A worker may assist another lane read-only but does not push competing edits to the same high-contention path.

## 5. Lane epochs
Every lane has an integer epoch. Takeover increments epoch.

A worker holding epoch N must stop writing when it observes a control directive or takeover at epoch N+1. Old branch remains recovery evidence, not automatic merge input.

## 6. Recommended lanes
- PROVIDER-P0 — provider routes, model/dialect contract, PR #12.
- CI-SHERIFF — red CI diagnostics and exact-head gate.
- RUNTIME-RECOVERY — cancellation/stream/recovery state.
- LOCAL-AI — llama lifecycle/device acceptance.
- FORGE-UX — mission loop.
- WORKSPACE — file/diff/artifact surface.
- RECEIPTS — History/evidence.
- CONTEXT — retrieval/memory provenance.
- ARCH — app/package boundary and monolith refactors.
- VISUAL-A11Y — simulator visual/accessibility loop.
- PERF — profiling.
- INTEGRATOR — conflict/dependency/release coordination.

Do not create many workers that all edit AppRootView.

## 7. High-contention ownership
Paths such as AgentRuntime.swift, AppRootView.swift, Models.swift, SwiftDataAgentStore.swift, project.pbxproj, CI workflows, and package provider core require explicit lane ownership or integrator-arranged sequencing.

Small parallel workers should prefer isolated tests/docs/components.

## 8. Worker startup algorithm
A worker receiving the Master Continuation Prompt must:
1. inspect live repository metadata/main SHA;
2. read README + AGENTS;
3. read constitution/current state/swarm OS;
4. inspect open PRs and control issue;
5. inspect CI status;
6. identify highest-priority unclaimed compatible lane;
7. verify dependencies;
8. post/record claim;
9. inspect representative implementation code;
10. execute actual work immediately;
11. checkpoint early;
12. validate;
13. open/update draft PR;
14. post handoff/evidence;
15. continue to the next useful unblocked task after merge/closure.

Do not reply with a giant planning essay and wait.

## 9. Engineering packet
A lane maintains a compact durable packet in its PR/body/control comment:
- worker;
- lane/epoch;
- base SHA;
- goal;
- paths owned;
- dependencies;
- facts discovered;
- implementation decisions;
- tests/evidence;
- remaining risks;
- exact head SHA;
- next action.

Source code/tests remain detailed truth.

## 10. Checkpoint strategy
Checkpoint after first meaningful reproduction, architecture seam, risky migration, significant refactor, green test milestone, and before broad integration.

Prefer small coherent commits/PR updates over one giant unreviewable drop.

## 11. Stale worker recovery
A worker may be stale when the control plane marks it stale, its lane blocks dependencies without progress, or its chat clearly terminated and no active owner exists.

Takeover:
1. inspect old branch/PR;
2. increment epoch;
3. record takeover;
4. choose continue/cherry-pick/start-clean;
5. never trust old unverified “done” claims;
6. re-run acceptance on the new exact head.

## 12. Recovery branches
Preserve risky abandoned work on a recovery branch when useful. Never merge a recovery branch merely to save effort. Recovery code re-enters through normal review/tests.

## 13. Integration coordinator
INTEGRATOR owns dependency DAG, merge order, high-contention scheduling, stale-base detection, conflict strategy, release candidate SHA and foreign-work quarantine. It coordinates evidence rather than rewriting every feature.

## 14. CI sheriff
CI-SHERIFF diagnoses failures on exact heads, distinguishes product/test from infrastructure failure, never disables tests merely for green status, preserves diagnostics, and blocks merge when required evidence is absent.

## 15. Provider reliability lead
PROVIDER-P0 has temporary priority until P0 exit. It owns route contract, picker/send compatibility, private-backend migration, provider errors, deterministic provider tests, and coordination with runtime recovery.

## 16. Visual/accessibility worker
VISUAL-A11Y must use:
SIMULATOR -> SCREENSHOT -> CRITIQUE -> IMPLEMENT -> INTERACT -> PROFILE/A11Y -> SCREENSHOT -> REPEAT.

It cannot declare quality from source code alone.

## 17. Performance worker
PERF starts from symptom/metric, profiles before speculative rewrite, records baseline/after, and avoids optimizations that remove correctness.

## 18. PR rules
Default PR is draft until acceptance evidence exists. PR body includes worker/lane/epoch/base and tests.

Before merge:
- intended base/current main as required;
- exact-head CI;
- no foreign files;
- unresolved review threads handled;
- scope acceptance;
- integrator merge order if overlapping.

Do not merge because GitHub merely says `mergeable=true`.

## 19. Post-merge continuation
After merge:
1. update current-state/roadmap if truth changed;
2. mark lane done;
3. release high-contention paths;
4. inspect dependency DAG;
5. claim next highest-value unblocked lane automatically.

Do not require the user to tell every chat “continue.”

## 20. Global directives
The control issue can publish:
`DIRECTIVE | protocol=<n> | effective=<UTC> | ...`

Workers read directives on startup and before major pushes/merges. A newer compatible GitHub directive may upgrade this protocol without requiring the master prompt to be re-pasted into every old chat.

## 21. Cross-project contamination firewall
Voltline or any unrelated project:
- is never a NovaForge lane;
- is not source of NovaForge requirements;
- must not enter main;
- should be migrated/quarantined by repo administration, not casually deleted.

If foreign files enter a worker diff, stop and clean them before PR.

## 22. Chat death reality
Workers cannot promise immortal/background execution. Every important fact must be durable before a chat disappears: claim, branch/PR, commits, tests, engineering packet, handoff.

The system succeeds when a replacement worker can resume without the old transcript.

## 23. Handoff format
`HANDOFF | worker=<id> | lane=<id> | epoch=<n> | head=<sha> | state=<ready|blocked|stale|needs-review>`

Then list accomplished, evidence, remaining, hazards, and next action.

## 24. Completion standard
A lane is DONE only when intended behavior exists, scope acceptance passes, exact-head evidence exists, PR is merged or explicitly rejected/superseded, current-state truth is updated where needed, and the claim is released.

“Code written” is not DONE.

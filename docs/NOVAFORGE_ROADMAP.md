# NOVAFORGE ROADMAP
Snapshot: 2026-08-06

Roadmap rule: reliability and trust gates outrank novelty. Every milestone ships evidence, not just code.

## Program 0 — Repository control and source-of-truth (P0)

### 0.1 Quarantine Voltline
- classify Voltline PRs/branches as foreign;
- do not merge into main;
- preserve history;
- move to a separate repo deliberately if still needed;
- retain only independently justified shared infrastructure.

Acceptance: no active NovaForge lane depends on Voltline paths, the control plane lists foreign work, and new workers are explicitly warned.

### 0.2 Durable docs/control plane
Maintain Product Constitution, Current State, Roadmap, AI Provider Contract, Design System, Release Acceptance and Swarm Operating System with non-overlapping purposes.

## Program 1 — Make send-message trustworthy (P0)

### 1.1 Repair/audit PR #12
- inspect failed Critical verification logs/artifacts;
- fix without weakening tests;
- update/rebase if main moved;
- exact-head CI required.

### 1.2 Remove private ChatGPT from fresh phone selection
- migrate saved private route safely;
- unknown/corrupt provider -> fail closed/local rather than an arbitrary network route;
- preserve valid public OpenAI/Zen/Local state.

### 1.3 Build model-dialect RouteDescriptor
- replace provider-wide endpoint assumptions with exact route contracts;
- support Zen Responses vs Chat Completions by model contract;
- capability negotiation;
- static offline fallback + live catalog validation.

### 1.4 Provider error UX
Normalized stable categories, actionable messages, expandable sanitized diagnostics, safe retry rules.

### 1.5 Stream/cancel/recovery integrity
- exactly one persisted assistant response;
- no blink/duplicate handoff;
- deterministic cancellation;
- partial-response semantics;
- coherent run state after provider failure;
- resumable run only where safe.

P0 exit: fresh install can select at least one supported hosted route, send, stream, cancel, retry/recover, and inspect a truthful receipt; no normal choice is known-broken.

## Program 2 — Local AI that tells the truth (P0/P1)
- resumable downloads;
- disk/memory preflight;
- model validation;
- local capability attestation;
- local-only privacy mode;
- physical iPhone 12 benchmark matrix;
- thermal/battery/memory-pressure behavior;
- realistic context and speed display;
- storage management.

Acceptance: interrupted download resumes, invalid model never becomes ready, local-only produces no hosted inference traffic, and supported models have physical-device evidence.

## Program 3 — Mission-first Forge (P1)
Goal: transform “chat with tools” into an engineering mission loop without theater.

Features:
- compact mission header: goal/project/route/state;
- useful plan/progress;
- condensed tool activity;
- inline approvals;
- evidence drawer;
- failed-step recovery;
- continue/fork.

Acceptance: user understands current task in seconds, tool detail expands on demand, completion claims link to evidence, and long conversations remain smooth.

## Program 4 — Workspace becomes a real engineering surface (P1)
- repository/project browser;
- fast search;
- syntax-highlighted preview;
- diff viewer;
- changed-files shelf;
- artifacts;
- terminal output;
- safe editor/mutation flow;
- rollback/revert;
- large-repo ergonomics;
- Git status awareness.

## Program 5 — Durable memory/context engine (P1)
- symbol/file-aware retrieval;
- context budget;
- pinned files/instructions;
- recent-change context;
- project fact store with provenance;
- stale invalidation;
- Memory Inspector;
- context receipt.

Acceptance: user can answer “why did the model know this?” and stale summaries cannot override live source.

## Program 6 — Trustworthy History/receipts (P1)
- exact route/model;
- approvals/tools/files/tests/artifacts;
- failures/retries;
- continue/fork;
- sanitized export/share.

Acceptance: a run can be reconstructed without old chat memory and attempted vs succeeded actions are unambiguous.

## Program 7 — Git/build/test workflow (P1)
- branch awareness;
- changed-file evidence;
- build/test actions;
- diagnostics parser;
- fix-failing-test and explain-diff missions;
- commit/PR support under policy;
- conflict awareness.

Acceptance: Git mutations require explicit policy, exact SHA is tracked, verification enters the receipt, and PRs cannot silently include unrelated changes.

## Program 8 — Architecture stabilization (P1)
Focus high-risk monoliths such as AppRootView, AgentRuntime, SwiftDataAgentStore, ChatView and oversized test files.

Method:
1. identify a real ownership/test/performance problem;
2. define seam;
3. move one responsibility;
4. preserve behavior;
5. test;
6. measure.

Target: AgentHarnessKit owns domain/provider/policy/store contracts; app services own iOS composition/platform adapters; views own presentation; observation is feature-scoped.

Do not package-split for aesthetics.

## Program 9 — Product visual system (P1 continuous)
SIMULATOR -> SCREENSHOT -> CRITIQUE -> REDESIGN -> IMPLEMENT -> INTERACT -> PROFILE -> ACCESSIBILITY -> SCREENSHOT -> REPEAT.

Priorities: content starts high, compact chrome, Forge hierarchy, readable stream/tool state, Workspace density, History evidence hierarchy, Control clarity, keyboard/composer, real empty/loading/error/offline states, light/dark/theme parity, Reduce Motion/Transparency/Contrast.

## Program 10 — Advanced engineering modes (P2)
Mission presets, not fake personalities:
- Code Review
- Debug
- Refactor
- Performance Audit
- Test Generation
- Release Check

Each defines context strategy, tool permissions, route requirements and acceptance evidence.

## Program 11 — Native iOS leverage (P2)
Evaluate only when useful:
- App Intents for safe read-only status/open-project actions;
- Share Sheet project/file ingestion;
- Live Activity for legitimate bounded active-mission state;
- widgets for project/run status;
- meaningful haptics;
- Spotlight indexing if privacy permits.

## Dependency DAG
0 Repository control
  -> 1 Provider reliability
      -> 2 Local AI truth
      -> 3 Mission Forge
          -> 4 Workspace
          -> 6 Receipts
              -> 7 Git/build/test
      -> 5 Context/memory
  -> 8 Architecture stabilization in controlled parallel
  -> 9 Visual/a11y/performance continuously
  -> 10 Advanced modes
  -> 11 Native integrations

## Definition of finished
A feature is finished only when behavior is implemented, tests/critical journey exist, errors/empty/offline are handled, relevant accessibility/performance/security/persistence risks are checked, exact-head evidence exists, and durable docs are updated if architectural truth changed.

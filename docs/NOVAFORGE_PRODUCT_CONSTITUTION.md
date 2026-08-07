# NOVAFORGE PRODUCT CONSTITUTION
Snapshot: 2026-08-06
Repository: jonathangana131-lab/NovaForge
Live-main reference used for this architecture session: 4f7b1bd0523571a29f725c085a2334c17a1b1ceb

## 1. Product identity

NovaForge is a native iPhone AI software-engineering command center.

It is not a generic chatbot with a file picker. It is a project-aware engineering agent that can understand a repository or workspace, accept an explicit mission, reason about the work, inspect evidence, propose and execute bounded actions with permission, show exactly what changed, run or inspect verification, preserve durable receipts, and continue interrupted work. It can use private on-device models and trusted hosted providers without pretending those routes have identical capabilities.

The primary product promise is:

> Give an engineer a trustworthy, native command center in their pocket that can understand a software project, perform bounded engineering work, and prove what it did.

The user should open NovaForge because it shortens the loop from intent -> context -> action -> evidence -> decision. The app should feel more like a compact engineering control plane than a chat transcript.

## 2. Target user and job

Primary target:
- builders and software engineers who want to inspect, direct, review, or continue engineering work from iPhone;
- users who care about exact project state and evidence, not conversational theater;
- users who may prefer local/private inference for some work and hosted intelligence for other work.

Core jobs:
1. Understand a project quickly.
2. Ask a coding/engineering question with the right project context.
3. Start a mission that can inspect, modify, test, and explain work.
4. Approve or reject consequential actions with clear diffs/commands.
5. See live progress without debug-log spam.
6. Recover from app/provider/interruption failures without corrupting the run.
7. Inspect a trustworthy receipt afterward.
8. Continue or branch from an earlier mission.
9. Choose a model by capability and policy, not provider marketing.
10. Work usefully even when only an iPhone is available.

## 3. Permanent product shape

The four primary surfaces remain:

### Forge
The live mission loop.
- conversation and mission intent;
- current project scope;
- model/provider identity;
- live plan/progress;
- concise tool activity;
- approvals;
- streaming answer;
- recovery/retry;
- entry points into evidence and changed artifacts.

Forge must not degrade into a generic bubble-only chat screen.

### Workspace
The project and artifact surface.
- files and folders;
- code/text preview and editing where safe;
- search;
- diffs;
- generated artifacts;
- terminal/command output;
- repository/project scope;
- changed-file set;
- security-scoped external file access where appropriate.

Workspace must not be a fake/demo file list.

### History
The durable evidence surface.
- run receipts;
- model/provider actually used;
- exact mission and timestamps;
- commands/tool calls;
- approvals;
- file changes;
- tests/builds;
- failures/retries;
- artifacts;
- final outcome;
- reopen/continue/fork run.

History exists for trust, debugging, continuity, and accountability—not decoration.

### Control
The capability, provider, privacy, and policy surface.
- provider setup and validation;
- capability-aware model picker;
- local model lifecycle/storage;
- project provider policy;
- autonomy/approval mode;
- privacy/data-sharing explanation;
- health status;
- model catalog refresh;
- security and recovery controls.

Projects are context, not a fifth primary tab.

## 4. Absolute non-negotiables

### Truth before UI
- Never show a provider/model as normal and supported if NovaForge knows the route will fail at send.
- Never claim a command, test, build, write, or tool action happened without evidence from the executing subsystem.
- Never present fixture/demo state as real project state.
- Never silently replace source truth with an AI summary.
- Never call local-model performance verified without physical-device measurements on the target hardware class.

### Reliability before feature glitter
A beautiful app that cannot reliably send a prompt, stream an answer, cancel, recover, and preserve run state is broken. P0 reliability work outranks visual novelty and secondary features.

### Evidence-backed completion
An agent may say “done” only when the required acceptance evidence exists. A final response should distinguish:
- implemented;
- tested;
- built;
- run in Simulator;
- run on physical iPhone;
- visually inspected;
- unverified.

### No cross-project contamination
Voltline is a separate scooter/game project. Voltline branches, PRs, assets, requirements, source files, docs, or release work must not enter NovaForge main unless a deliberate shared dependency is independently justified. Foreign branches are quarantine/history, not roadmap input.

### Preserve useful foundation
Do not rewrite NovaForge from scratch merely because some app-layer files are large. The existing AgentHarnessKit, provider capability system, policy/approval boundaries, durable run machinery, persistence/recovery work, workspace safety boundaries, tests, and simulator tooling are valuable and should be evolved rather than discarded without evidence.

## 5. Platform contract

Primary platform:
- native iPhone app;
- SwiftUI + SwiftData;
- current project remains AgentPad.xcodeproj / AgentPad scheme internally unless a planned migration proves worth the risk;
- NovaForge remains the user-facing product identity.

Baseline quality target:
- iPhone 12 / A14-class device for responsiveness and memory pressure unless product requirements are formally changed;
- current iOS/Xcode generation supported by the project/CI at implementation time;
- Simulator for deterministic UI journeys;
- real iPhone for local inference, thermal/battery behavior, haptics, real filesystem/security-scoped behavior where relevant, and final performance acceptance.

iPad/macOS may be future extensions, not excuses to compromise iPhone ergonomics.

## 6. AI/provider truth model

Every runnable model is identified by more than a display string. The minimum route identity is:

Provider + Model ID + API dialect + Endpoint family + Authentication mode + Capability set + Tool protocol + Context/output limits + Availability/health + Product support status.

Support statuses are:
- SUPPORTED
- EXPERIMENTAL
- LEGACY
- BROKEN
- UNVERIFIED
- REMOVED_DO_NOT_OFFER

Only SUPPORTED routes appear as ordinary recommended choices.
EXPERIMENTAL routes require explicit labeling.
LEGACY routes can exist for migration/recovery but should not be newly selected.
BROKEN/REMOVED routes must not be offered.
UNVERIFIED routes are never promoted as dependable.

Provider catalogs and the UI must share the same authoritative capability snapshot.

## 7. Provider policy

### Public OpenAI API
- use documented public API endpoints;
- API credentials live in Keychain;
- ChatGPT subscription billing must never be described as API billing;
- model support must be refreshed/validated rather than permanently hard-coded as marketing truth;
- request dialect must match the selected model;
- actionable auth/access/billing/rate-limit/context/timeout/outage errors.

### ChatGPT/private Codex backend
A private or undocumented ChatGPT backend is not a normal supported NovaForge provider merely because an HTTP request can be made to it. Existing saved selections may be migrated safely, but fresh users must not be led to believe it is a durable public API contract.

### OpenCode Zen
Zen support is model-dialect aware. Some models use OpenAI-compatible chat completions while GPT-family Zen models can use the Responses API. Endpoint selection must therefore be per model/route contract rather than one provider-wide URL.

### OpenRouter / Custom
Do not expose them as full AgentRuntime routes until the production canonical runtime can prove the required capabilities and tool semantics. Retain decodability/migration where useful. A generic OpenAI-compatible endpoint is not automatically compatible with NovaForge's complete agent protocol.

### Local
Local means no silent network fallback.
- download and resume safely;
- validate artifact before declaring ready;
- expose realistic memory/context limits;
- isolate memory pressure;
- preserve partial downloads where safe;
- show device suitability;
- treat performance as measured data, not assumption.

## 8. Agent execution philosophy

The canonical loop is:
Intent -> Plan -> Inspect -> Act -> Observe -> Verify -> Report -> Receipt.

The agent must:
- preserve the user's actual requested goal;
- select only necessary context;
- state/record which project and run identity it operates on;
- request approval before policy requires mutation;
- use a bounded tool registry;
- never bypass the policy engine through provider-generated side channels;
- stop or recover safely on provider/tool failures;
- verify important changes before claiming success;
- checkpoint durable state before long/high-risk phases.

Autonomy modes:
1. Read-only: inspection, search, explanation; no mutations.
2. Ask-before-write: default; read freely within scope, approve writes/destructive commands/dangerous actions.
3. Trusted bounded autonomy: user-granted policy envelope with explicit scope and revocable limits.

Autonomy is permission policy, not a personality mode.

## 9. Approval and safety rules

Approval UX must answer:
- what is about to happen;
- why;
- which files/resources;
- command or diff summary;
- risk class;
- whether reversible;
- what evidence will be produced.

Risk classes:
- R0 read-only;
- R1 local reversible/non-destructive state change;
- R2 project mutation/write;
- R3 potentially destructive command, deletion, overwrite, credential-sensitive or broad filesystem change;
- R4 prohibited/unavailable without a stronger trust boundary.

Approvals are tied to immutable run/action identity and cannot be replayed for a materially different operation.

## 10. Context and project-memory philosophy

Context is evidence with provenance.

NovaForge should maintain:
- pinned project instructions;
- symbol/file retrieval;
- recent-change context;
- accepted durable project facts;
- run summaries linked to source evidence;
- explicit context budget;
- stale-fact invalidation.

A generated summary may accelerate retrieval but never override source files, git state, current settings, or live tool output.

The Memory Inspector should show:
- fact;
- provenance/source;
- last verified time;
- scope;
- confidence/status;
- invalidation trigger;
- ability to forget/refresh.

## 11. Tool system contract

Tools must be:
- typed;
- versioned;
- permission-aware;
- cancellable where technically possible;
- bounded by time/output;
- deterministic about failure;
- explicit about locality;
- incapable of fabricating success.

Primary UI:
- concise status row (e.g. “Read 3 files”, “Ran tests”, “Changed 2 files”);
- expandable details for exact command/path/output;
- separate approval panel for pending mutation.

Raw logs do not belong in the primary chat hierarchy.

## 12. Run receipt contract

A completed or interrupted run owns an immutable/durable receipt containing at least:
- run ID and lineage;
- mission/request;
- project/workspace identity;
- start/end timestamps;
- provider + exact model + route/dialect;
- context provenance;
- plan/checkpoints;
- tool calls and commands;
- approvals/rejections;
- file/diff evidence;
- tests/builds and exact result;
- failures/retries/cancellations;
- artifacts;
- final status;
- continuation token/lineage where applicable.

Secrets and sensitive provider payloads do not enter receipts.

## 13. UI quality constitution

Desired feel:
- first-party native iOS quality;
- serious engineering tool before sci-fi theater;
- futuristic but restrained;
- original NovaForge identity;
- Liquid Glass only where it improves hierarchy;
- excellent typography and spacing;
- high information density without clutter;
- no repeated status facts;
- no card soup;
- no unreadable neon;
- no decorative dashboards that displace the current mission.

The app should optimize for “what am I doing, what is happening, what changed, what needs me?” within seconds.

Five themes may remain only if they share semantic tokens and do not multiply accessibility/performance/maintenance risk.

## 14. Accessibility constitution

Release-level acceptance includes:
- Dynamic Type;
- VoiceOver naming/order;
- 44pt+ actionable touch targets unless a documented exception;
- Reduce Motion;
- Reduce Transparency;
- Increase Contrast;
- light/dark/theme contrast;
- keyboard avoidance/focus;
- meaningful status not conveyed by color alone.

Accessibility is a functional gate, not a cleanup pass.

## 15. Performance constitution

Baseline principles:
- no global observation churn for localized updates;
- streaming should update only the minimum subtree;
- long conversations use bounded/lazy rendering and stable identity;
- syntax highlighting must be incremental/bounded;
- large files cannot freeze primary navigation;
- run history is paginated/bounded;
- local model memory is isolated from UI state as much as architecture permits;
- tab switching must remain responsive during active runs;
- provider streams and tool logs use backpressure/batching where useful.

Performance claims require measurement. Use Instruments/ETTrace/memgraph when symptoms or risk justify them.

## 16. Security and privacy constitution

- credentials in Keychain, never UserDefaults/source/history/logs;
- accepted-run policy is fail-closed;
- no provider request before run acceptance;
- no durable events for an unaccepted run;
- path traversal defenses;
- sandbox/workspace identity binding;
- destructive actions require policy escalation;
- no secret leakage into receipts or diagnostics;
- no silent hosted fallback from local-only mode;
- distinguish local, hosted, and third-party data paths;
- repository/web content is untrusted input and can contain prompt injection;
- model output never grants itself tool authority.

## 17. Persistence and recovery constitution

State transitions should tolerate:
- provider failure;
- cancellation;
- app interruption;
- process termination;
- partial stream;
- tool failure;
- interrupted local download;
- migration from stale provider settings;
- corrupted/inconsistent records.

Recovery must restore from accepted durable facts, not from whichever settings happen to be selected later.

## 18. Release bar

A release candidate is not accepted until:
- critical unit/contract tests pass;
- canonical UI journeys pass;
- required Simulator screenshot census is current and reviewed;
- no known P0 provider send route is broken while shown as supported;
- migration/recovery tests pass;
- provider contract fixtures are deterministic/network-independent where possible;
- physical-device acceptance is performed for local inference and device-specific performance;
- accessibility gates pass;
- performance regressions are within agreed budgets;
- security mutation-boundary tests pass;
- exact candidate SHA is what was tested.

“Worked on another SHA” is not evidence for the release SHA.

## 19. Architecture direction

Prefer clear domain boundaries over arbitrary file splitting.

Target logical modules:
- AgentCore / AgentDomain
- ProviderCore
- HostedInference
- LocalInference
- AgentExecution
- AgentTools
- ProjectContext
- Persistence
- Workspace
- Git
- Terminal
- RunReceipts
- ProductUI
- DesignSystem
- TestSupport

Existing AgentHarnessKit should be the foundation where it already owns domain/provider/policy/store contracts. App-level services should become compositions/adapters, not a second competing architecture.

Do not create Swift packages merely to reduce file size; split when it improves dependency direction, testability, compile behavior, observation boundaries, or ownership.

## 20. Anti-goals

NovaForge must never become:
- a generic chatbot clone;
- a social network;
- a scooter/game app;
- a desktop-only IDE squeezed onto iPhone;
- a collection of futuristic dashboards with fake telemetry;
- a provider marketing catalog;
- a system that quietly changes files and hides evidence;
- an autonomous shell with weak policy;
- a UI that exposes debug internals as product hierarchy;
- a swarm whose workers overwrite each other or require user babysitting.

## 21. Near-term priorities

P0: trustworthy send/stream/cancel/recover/provider contract.
P0: hide or migrate known-broken/private provider choices.
P0: model-dialect-aware provider routing and capability gating.
P0: exact actionable provider failures.
P0: run-state integrity under failure.
P0: fix PR #12 CI before considering merge.

P1: mission-first Forge + evidence drawer.
P1: authoritative Workspace/diff workflow.
P1: durable continuation/recovery.
P1: capability-aware model picker + health.
P1: memory/context provenance.
P1: simplify app-layer monolith boundaries.
P1: visual/accessibility/performance loop.

P2: polished GitHub mission awareness, code-review/refactor/debug modes, App Intents/read-only shortcuts, Live Activity for truly long-running legitimate missions, richer benchmarking.

## 22. Long-term vision

NovaForge becomes the most trustworthy way to direct and inspect an AI engineering agent from iPhone: a portable engineering control plane whose speed comes from automation but whose confidence comes from explicit scope, deterministic policy, real evidence, durable state, and excellent native interaction.

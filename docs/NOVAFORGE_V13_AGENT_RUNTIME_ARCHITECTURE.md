# NovaForge v13 Agent + Runtime Architecture

This document turns the NovaForge 2.0 product constitution into engineering boundaries. It is intentionally product-first: architecture exists to make the iPhone creation experience durable, fast, truthful, and extraordinary.

## 1. Core architectural invariant

A **mission** is the durable authority. A model conversation is not.

The mission owns:

- user intent and Mission Constitution;
- project identity;
- accepted plan and dynamic stage graph;
- autonomy/privacy/resource policy;
- current execution environment;
- structured project memory;
- checkpoints;
- in-flight and accepted tool operations;
- test/visual/performance evidence;
- completion state;
- continuation lineage.

Models are workers attached to a mission. They can be replaced without losing mission state.

## 2. Suggested module seams

Names are provisional; separation is not.

### ForgeMission
Durable mission domain, stage graph, plan decisions, budgets, interruption, pause/resume, user steering, completion criteria.

### ProjectBrain
Structured source-backed memory: intent, Design DNA, feature graph, files/symbols, accepted decisions, unresolved blockers, provenance, staleness.

### AgentCore
Plan/act/observe/verify engine. Converts mission state into bounded model/tool work. No provider-specific UI logic.

### AgentPolicy
Autonomy, approval, risk, privacy, locality and execution constraints. Model output cannot mutate policy.

### AgentTools
Typed, bounded tool contracts and receipts. Separate reads from mutations. Preserve idempotency/recovery semantics.

### ProviderRuntime
Exact route capability resolution: provider/model/dialect/auth/stream/tool/reasoning/context/cancel/error contracts.

### ModelCatalog
Dynamic compatible local/cloud model metadata and support states.

### ModelRuntime
Local llama.cpp lifecycle, downloads, validation, device compatibility, memory/thermal recovery, benchmark.

### ForgeRuntime
Sandboxed runnable-project host: manifest, HTML/CSS/JS/Canvas/WebGL, curated libraries, storage, orientation, launch lifecycle, runtime errors, live reload, screenshots and performance evidence.

### RuntimeBridge
Explicit permissioned bridges between generated project and host capabilities. Never arbitrary native authority.

### VisualQA
Screenshot capture, visual baselines, motion-frame inspection where justified, critique inputs, regression signals, Auto-Polish orchestration.

### ProjectTesting
Semantic recorded interactions, generated acceptance flows, runtime tests, adversarial journeys, evidence capture.

### ProjectHistory
Checkpoint store, restore/fork/compare, visual time machine, receipts, project evolution.

### ExecutionWorkers
Execution-environment abstraction with explicit provenance: iPhone, supported background task, real cloud worker, paired Mac.

### AppShell / DesignSystem
NovaForge 2.0 native shell, navigation, materials, motion, haptics, accessibility and common control patterns.

## 3. Mission state machine

A mission should distinguish at least:

- draft intent;
- planning / needs decision;
- ready;
- executing;
- paused by user;
- paused by policy/approval;
- blocked by external dependency;
- interrupted/recoverable;
- validating;
- polishing;
- completed with evidence;
- completed with known limitations;
- cancelled;
- failed irrecoverably.

Do not collapse disconnected/suspended/unknown into failed or complete.

Stage graph is dynamic. A validation finding may add a repair stage; user steering may defer an optional stage; a provider failure may change worker without changing mission identity.

## 4. Mission Constitution

Generate a concise accepted contract from user intent.

Possible fields:

- product goal;
- target project type;
- design intent / Design DNA seed;
- orientation/device target;
- required capabilities;
- explicit non-goals;
- build depth;
- creativity/refactor preferences;
- privacy/locality;
- performance target;
- accessibility target;
- persistence expectations;
- acceptance journeys;
- expected evidence classes.

User can edit it. Agent cannot silently weaken it.

## 5. Plan Space data model

Questions should be structured decisions, not prose-only messages.

A plan decision can have:

- stable ID;
- question/purpose;
- why it matters;
- control type (choice, slider, range, visual variant, orientation, text, Decide for me);
- options and consequences;
- preview capability if legitimate;
- required vs skippable;
- chosen answer and provenance;
- whether answer affects Design DNA, runtime capabilities, mission stages, or acceptance.

Only ask a question when the expected value of the answer is meaningful. Default to safe inference otherwise.

## 6. Agent loop

Canonical durable loop:

`understand -> decide if question needed -> retrieve context -> plan bounded step -> choose worker/model -> request tool/model work -> observe -> verify -> checkpoint -> update project brain -> continue`.

For product work, layer in:

`run -> visual inspect -> accessibility -> performance -> repair -> retest`.

A worker response is not automatically accepted state. Acceptance requires the relevant evidence/policy boundary.

## 7. Context virtualization

Do not repeatedly serialize full chat + full repository.

Use source-backed retrieval composed from:

- current mission stage;
- project graph neighborhood;
- exact files/symbols;
- recent accepted diffs;
- relevant user decisions;
- Design DNA;
- related tests/errors;
- runtime evidence;
- compact prior-stage summaries;
- provider context budget.

Persist provenance so a summary can be refreshed when source changes.

## 8. Long-mission compaction

After many steps, build durable summaries of *accepted* work:

- what changed;
- why;
- accepted architecture decisions;
- remaining problems;
- tests/evidence;
- important source locations;
- user preferences specific to project;
- next safe stages.

Do not summarize unaccepted speculative model text into project truth.

## 9. Tool transaction model

For mutations, prefer an explicit transaction pattern:

1. create bounded proposed operation;
2. policy/approval if required;
3. capture precondition/project identity;
4. stage mutation;
5. validate syntactic/structural invariants;
6. apply/commit accepted state;
7. run required verification;
8. record receipt;
9. rollback/recover if validation fails.

Not every trivial local edit needs heavyweight transactions, but multi-file/high-risk operations must not leave random half-written state after cancellation/provider death.

## 10. Risk / approval

Illustrative risk classes:

- R0: read-only inspection;
- R1: reversible local/project UI state;
- R2: project source mutation;
- R3: destructive action, credentials, broad shell, publishing, remote mutation;
- R4: unavailable/prohibited until a stronger architecture exists.

Approval binds to exact action/scope. A model cannot reuse approval for a materially different operation.

## 11. Multi-model orchestration

Roles are internal execution concepts, not separate user chats.

Potential roles:

- Builder;
- Reviewer;
- Visual Director;
- Adversarial User;
- Performance Reviewer;
- Simplicity Reviewer.

Each role gets only relevant context and authorized tools. Outputs re-enter the mission through explicit acceptance/review steps.

Auto-routing should consider support status, capability, privacy, latency, observed project success, user lock, and resource policy.

## 12. Reasoning / intelligence controls

The user-visible intelligence control must be capability-aware.

If provider supports native reasoning effort, map to documented values.

If not, NovaForge can vary:

- planning passes;
- reviewer count;
- context retrieval depth;
- test breadth;
- visual critique depth;
- subproblem decomposition;
- model choice.

Never show a fake provider reasoning level.

## 13. Forge Runtime manifest

A runnable project manifest should be versioned and explicit.

Candidate fields:

- project ID/version;
- runtime version;
- entry point;
- display name/icon;
- orientation policy;
- viewport/safe-area policy;
- capability requests;
- network policy;
- storage namespace/version;
- bundled assets;
- curated modules/versions;
- launch/splash metadata;
- controller/touch mappings;
- test fixtures;
- migration hooks where safe.

Reject unsupported/unknown critical capabilities instead of silently pretending they work.

## 14. Forge Runtime sandbox

Generated code is untrusted.

Isolate projects by project identity/storage namespace. Apply explicit network/capability policy. Do not expose arbitrary file system, credentials, native command execution, provider keys, or host internals.

A project cannot grant itself new capabilities by writing a manifest at runtime without host approval/policy.

## 15. Runtime bridge

Bridges must be curated, versioned and narrow. Examples:

- haptics;
- share;
- local project storage;
- photo/file picker;
- controller state;
- permitted app metadata;
- later location/camera/microphone only with explicit system + NovaForge permission.

Each bridge operation has a truthful async result and failure semantics.

## 16. Runtime orientation / presentation

Project-level orientation can be portrait, landscape, auto, or advanced mixed layouts where host architecture supports it. Transitions must be tested on iPhone 12/iOS 27 and not strand the user in broken shell orientation.

Run mode should minimize NovaForge chrome and feel like the user's creation, while providing a reliable escape/back gesture/control that is accessible and does not conflict with the project.

## 17. Live reload

Live reload is allowed only where runtime state migration is safe.

Classify changes:

- style/asset hot reload;
- script/module reload;
- full runtime restart required;
- storage/schema migration required.

Do not call a restart-free change live reload if the runtime actually reset important state without disclosure.

## 18. Runtime error pipeline

Capture:

- exception message;
- stack;
- source location/source map if available;
- current runtime version;
- project checkpoint;
- recent semantic interactions;
- console errors/warnings bounded by size;
- related asset/network failure.

Crash Doctor can convert this to a repair submission.

## 19. Visual Picker

For DOM/UI runtime, maintain stable element/source mapping where feasible.

Selection evidence can include:

- element identity;
- bounds;
- semantic role;
- relevant source file/range;
- style tokens;
- parent hierarchy;
- screenshot crop;
- current computed values.

The agent should not guess which `this` the user means when the runtime can provide exact selection identity.

## 20. Game/scene inspector

Scene-capable kits should provide stable entity identity and source/config association for selectable objects. Debug identity must never leak as user-facing ugliness in normal Run mode.

## 21. Test recording

Record semantic actions where possible:

- button/control ID;
- text input role;
- selected entity/control;
- gesture intent;
- orientation;
- runtime milestone.

Raw coordinates may supplement, but should not be the only source when semantic selectors exist.

## 22. Visual QA evidence

A visual acceptance record may include:

- exact project checkpoint;
- runtime version;
- device/simulator identity;
- orientation;
- accessibility environment;
- screenshot/frame sequence;
- accepted baseline relation;
- critic findings;
- user acceptance/protection markers.

Simulator screenshots are visual software evidence, not physical-device performance proof.

## 23. Model catalog architecture

Separate catalog facts from device observations.

Catalog facts:

- model/revision/source/license;
- architecture;
- parameter count;
- file variants/quantization;
- tokenizer/template;
- context claims from source;
- known runtime compatibility.

Device observations:

- installed file integrity;
- actual load success;
- measured tokens/sec;
- memory/thermal events;
- tool/grammar success;
- benchmark result;
- stability.

Compatibility UI should state what is measured, inferred, source-reported, or untested.

## 24. Local download state

Use durable states such as:

- available metadata;
- queued;
- downloading with exact bytes;
- paused/resumable;
- validating;
- ready;
- incompatible;
- corrupted;
- failed/retryable;
- removing.

Do not discard partial bytes unnecessarily after network interruption.

## 25. Device capability / thermal strategy

Model/runtime selection can observe OS-provided memory/thermal conditions and known device class. Do not invent exact free-RAM facts the system does not provide.

When memory pressure rises, prefer safe checkpointing/unloading of nonessential caches/models over mission corruption.

## 26. Background/continued processing

On-device background work is opportunistic and system-governed.

Architecture must support:

- user-started continued-processing request where eligible;
- durable progress checkpoint before and during execution;
- cancellation/expiration callback handling;
- restart from last accepted checkpoint;
- Live Activity/system status that does not claim work is still running if the process stopped;
- background URLSession for supported transfers.

Cloud continuation is a different execution environment, not a hack to pretend the iPhone stayed alive.

## 27. Cloud continuation contract

Only implement when a real backend exists.

A cloud worker receives:

- exact mission ID/checkpoint;
- authorized project snapshot/context;
- allowed tools;
- privacy policy;
- resource budget;
- expected evidence.

Return results as signed/identified receipts or equivalent trustworthy provenance. Phone reconciles by mission/checkpoint identity and rejects stale conflicting results.

## 28. Mac Worker contract

Optional paired worker should advertise actual capabilities/version/availability. A Mac is not assumed merely because the user owns an iPhone.

Native tasks bind to exact project/checkpoint and return build/test/simulator/device/profiling evidence with clear environment identity.

## 29. History / checkpoints

Checkpoint should distinguish:

- accepted project source/state;
- visual preview;
- mission stage;
- test status;
- runtime state schema version;
- parent lineage.

Do not store a 100 MB duplicate tree every tiny edit if a more efficient immutable/delta architecture can preserve reliability.

## 30. Human edits / Take Over

Human changes are authoritative project mutations. If they collide with an in-flight agent stage, pause/reconcile rather than silently overwriting.

## 31. Provider truth boundary

One authoritative route resolver feeds both UI and runtime. A model shown as Supported must actually have a route whose endpoint/dialect/auth/stream/tool/context/error semantics are implemented and validated for the advertised capabilities.

Catalog presence alone is not support.

## 32. Private/local truth

Local-only missions cannot call hosted providers or remote agent tools unless the user changes the policy. Project runtime network permission is separate from model inference privacy and must be separately represented.

## 33. Performance architecture

Avoid whole-app observation churn. High-frequency streams belong in localized models/views. Long histories and file lists require virtualization/paging/efficient queries. Runtime frame loops must not publish global SwiftUI state every frame.

Measure before and after major refactors.

## 34. Accessibility architecture

Semantic state must exist independently of animation. VoiceOver should announce accepted model/tool/mission facts, not every interpolated visual frame. Plan Space controls require labels/values/actions and non-motion equivalents. Dynamic Type must not destroy the primary Forge flow.

## 35. Migration strategy

Before retiring old shell/state:

1. inventory durable SwiftData/project/provider/model records;
2. decide which are user value vs internal legacy;
3. define migration schema and rollback/recovery;
4. test with representative old stores/settings;
5. preserve credentials securely;
6. migrate project/history truth without carrying forward bad view architecture.

## 36. Product-closure architecture rule

Do not keep adding foundations forever. Once a domain contract is trustworthy enough, climb the ladder into app wiring, UX, runtime, visuals, accessibility and performance.

The architecture succeeds only when the user can make and run excellent software with minimal friction.

# NovaForge V14 — Local AI + Autonomous Forge Product Direction

**Status:** binding V14 product/runtime direction for NovaForge 2.0 unless live evidence supersedes a technical detail.  
**Goal:** make NovaForge an exceptional iPhone-native creation system whose default superpower is **local models that can autonomously build, run, inspect, play-test, repair, and polish software until the accepted product definition is genuinely complete**.

This document extends the V13 product constitution; it does not replace provider/security/migration truth.

---

## 1. Product north star

NovaForge should not feel like “ChatGPT with a code button.”

The normal experience should feel closer to an intelligent creation instrument:

`DESCRIBE -> UNDERSTAND -> FORGE -> RUN -> EXPERIENCE -> CRITIQUE -> REPAIR -> POLISH -> COMPLETE`

The user can stay simple while the system underneath is sophisticated.

The default public promise is:

> Describe what you want. NovaForge builds the real thing, runs it, checks it, improves it, and shows you why it believes the result is finished.

Local-first is a first-class product identity, not a settings afterthought. Cloud models may be optional accelerators when explicitly enabled, but local-only must remain genuinely local-only.

---

## 2. The Forge Composer must become a flagship surface

The Composer is not a generic text field.
It is the front door to the entire creation OS and should receive flagship-level design effort.

### Resting state

One calm, premium creation field with almost no chrome:

**What do you want to make?**

It can accept text, pasted code, screenshots, images, project references, files, and voice where available.

The model/runtime state is visible only when useful, e.g. a compact truthful status such as:

`On-device • Ready`

Do not show unmeasured token/s, fake intelligence scores, or technical clutter in the primary hierarchy.

### Adaptive composer

As intent becomes clear, the Composer can fluidly reveal only relevant controls:

- **Autonomy:** Guide me / Collaborate / Full Forge
- **Build Depth:** Quick / Complete / Obsessive
- **Intelligence:** Auto or explicit compatible model
- **Privacy:** Local only / Allowed providers
- **Creativity:** Conservative -> exploratory
- **Refactor Risk:** Preserve -> rebuild if needed
- **Run Target:** utility / 2D / 3D / web-style app / supported native surface

These controls should feel like part of one coherent instrument, not a settings form.

### Plan Space bloom

When material questions exist, the Composer should expand into **Plan Space** rather than dumping a numbered questionnaire into chat.

Plan Space can include:

- visual choices;
- generated mini-previews;
- sliders where a scalar decision is real;
- side-by-side interaction concepts;
- “Decide for me” for every delegable choice;
- one-line consequence explanations;
- live mission-cost/resource implications where measured;
- explicit protected design decisions.

Plan Space should disappear when no real decision remains.

### Main action morph

The primary action should morph with product state instead of keeping one generic send arrow:

`Describe` -> `Plan` -> `Forge` -> `Watch` -> `Run` -> `Improve`

The exact labels can evolve through visual testing, but the principle is one obvious next action.

---

## 3. Full Forge — true autonomous mode

**Full Forge** is a user-visible autonomy mode, not a marketing label.

When enabled, NovaForge may continue through all safe delegated decisions allowed by the Mission Constitution without stopping after each tool call.

Core loop:

`PLAN -> IMPLEMENT -> BUILD -> RUN -> OBSERVE -> PLAY/INTERACT -> TEST -> VISUAL CRITIQUE -> REPAIR -> REGRESSION -> PERFORMANCE/A11Y -> POLISH -> ACCEPT OR LOOP`

A model response is never proof of completion.
Completion is earned from evidence.

### Full Forge requirements

- durable Mission Engine independent of raw chat transcript;
- exact Project Brain facts + source/revision provenance;
- bounded dynamic stage graph;
- atomic/staged project mutation;
- restart/relaunch recovery;
- model hot-swap without losing accepted state;
- explicit user interruption/steering;
- hard resource/time/thermal budgets;
- deterministic evidence receipts;
- safe stop on unresolved material decisions;
- no fabricated pass results.

### Completion Constitution

Every mission has an explicit machine-readable definition of done.
For a generated game this may include:

- builds successfully;
- launches successfully;
- no fatal runtime error across accepted test journeys;
- controls are reachable and responsive;
- main gameplay loop is reachable;
- win/loss/restart or equivalent project goals are reachable when specified;
- save/recovery works when required;
- orientation/safe-area behavior is correct;
- key UI fits the target viewport and Dynamic Type policy;
- visual quality passes accepted screenshots;
- accessibility requirements pass where applicable;
- performance stays inside measured/declared target budgets;
- no unresolved critical/high defects;
- known limitations are explicit and accepted rather than hidden.

“Complete” is a product state backed by receipts, not an assistant adjective.

---

## 4. Autonomous Playtest Engine

NovaForge should be able to test generated games by **actually playing them** through Forge Runtime.

### Semantic input bridge

Forge Runtime should expose a test-only semantic input API for generated projects:

- move vector;
- look/aim vector;
- primary/secondary action;
- jump/brake/interact;
- menu/navigation actions;
- restart/pause;
- controller-equivalent actions.

The runtime owns safety and capability authorization. Generated code cannot grant itself new host permissions.

### Playtest agents

Use several play styles rather than one scripted happy path:

1. **Goal runner** — tries to complete the main objective.
2. **Explorer** — deliberately visits boundaries and alternate paths.
3. **Chaos tester** — presses conflicting controls, rotates device, pauses/resumes, backgrounds/reloads where supported.
4. **New-player tester** — acts with minimal knowledge to test onboarding/discoverability.
5. **Persistence tester** — saves, exits, restores, resumes.
6. **Performance path** — seeks effect-heavy/entity-heavy scenes.

### Evidence captured per run

- deterministic seed/input trace when possible;
- runtime event log;
- crash/error log;
- screenshots/key frames;
- state/progress milestones;
- control latency measurements when available;
- frame-time/performance samples where supported;
- save-state/reload receipts;
- discovered defects tied to project revision.

### Visual-world feedback

Use render output as a first-class signal:

- screenshot understanding;
- semantic DOM/runtime element map when available;
- stable source/runtime element IDs;
- viewport/clipping checks;
- contrast/readability checks;
- stuck-screen detection;
- “generic template” visual critique;
- before/after screenshot comparison.

For supported generated web/runtime projects, prefer renderable-code/world-state inspection in addition to pixels so the verifier can reason about both actual pixels and source-linked elements.

---

## 5. Autonomous repair loop

A failing test should automatically become a new bounded repair mission when policy allows.

`DEFECT -> LOCALIZE -> PATCH -> FOCUSED TEST -> FULL JOURNEY -> VISUAL REGRESSION -> ACCEPT/RETRY`

Important rules:

- do not keep patching the symptom if the same defect class repeats;
- after repeated failure, promote to architecture/root-cause analysis;
- preserve a known-good checkpoint before risky repair;
- compare metrics/screenshots against the last accepted checkpoint;
- never mark a flaky/timeout test as passed merely to terminate the loop;
- cap autonomous retries and surface a clear blocker if evidence stops improving.

---

## 6. Local AI is the primary runtime, not a side feature

NovaForge should maintain a **Local Model Fabric** rather than one hard-coded GGUF picker.

The fabric chooses the smallest/fastest model that can reliably do the current role.

Possible roles:

- intent/router;
- retrieval/query rewriting;
- planner;
- code editor;
- test/bug critic;
- visual critic;
- summarizer/compactor;
- tool caller;
- high-difficulty escalation model.

One model can fill multiple roles, but NovaForge should not require a large model for every tiny operation.

### Model ladder

A device-specific ladder should classify models as:

- **Instant** — tiny, always-resident or very cheap model for routing/compaction.
- **Core** — default local agent model.
- **Deep** — slower/larger local model used for difficult planning/repair when memory allows.
- **Experimental Beyond-RAM** — larger model enabled through flash/expert streaming or other experimental memory modes with explicit speed/battery/storage warnings.

Model compatibility must be measured on exact device/runtime/quant/context, not guessed from parameter count.

---

## 7. Current model families worth first-class investigation

These are research targets, not automatic support claims. Every model requires exact runtime + device qualification before NovaForge labels it supported.

### Liquid LFM2.5 family

High-priority edge candidates because the family explicitly targets on-device deployment.

Investigate at minimum:

- LFM2.5-230M / 350M for tiny routing, classification, rewrite, extraction or compaction roles;
- LFM2.5-1.2B-Instruct / 1.2B-Thinking as potential fast local agent tiers;
- LFM2.5-8B-A1B as an experimental MoE/deep tier: 8.3B total, about 1.5B active, with GGUF support. It is not automatically an iPhone 12 coding model; qualify it honestly and consider flash/expert streaming experiments.
- LFM2.5 small encoders for local retrieval/routing so generative models do less unnecessary work.

### Qwen small-agent family

Continuously test current small Qwen generations such as Qwen3.5-class ~4B models when licenses/runtime support permit. Do not infer strong coding capability from family name; run NovaForge’s coding/tool/runtime benchmark.

### Native low-bit / BitNet

Treat native 1.58-bit models as a dedicated experimental lane, not merely another post-training quant.

Microsoft BitNet b1.58 2B4T and bitnet.cpp demonstrate a real native ternary/1-bit direction with ARM CPU kernels. NovaForge should investigate whether a mobile-safe BitNet runtime can provide a much lower-memory always-available planner/tool model or specialist fine-tunes.

### Task-specific tiny models

NovaForge should be willing to use a 200M–1B specialist instead of a 4B general model when the job is narrow:

- intent routing;
- symbol/file ranking;
- diff-risk classification;
- screenshot defect tagging;
- log classification;
- context compression;
- tool selection;
- test-result summarization.

The right architecture is a local AI system, not a single giant chatbot.

---

## 8. Forge Compact — aggressive memory/context system

Create a dedicated memory-efficiency subsystem (working name **Forge Compact**).

It has two separate jobs:

1. reduce **model runtime memory**;
2. reduce **agent context/prompt memory and re-processing**.

Do not conflate them.

### A. Weight memory strategies

Supported/experimental adapters may include:

- GGUF K-quants and I-quants where exact model/runtime quality is acceptable;
- native BitNet/ternary weights;
- mixed precision by tensor importance;
- quantized embeddings where validated;
- model-specific low-bit profiles selected from measured quality curves, not a universal “Q4 is best” assumption.

### B. KV-cache compression

Long autonomous missions can become KV-memory bound even when weights fit.

Investigate:

- Q8/Q4 KV cache modes already supported by llama.cpp/Metal;
- adaptive KV precision based on token importance;
- TurboQuant-style extreme KV compression as an experimental backend when a trustworthy implementation exists;
- separate draft-model KV compression for speculative decoding;
- context-window auto-sizing from current memory pressure instead of one static maximum.

Quality must be benchmarked on NovaForge’s coding/tool tasks at long context before a compressed profile is promoted.

### C. Flash-backed / beyond-DRAM inference

Create an **Experimental Beyond-RAM** mode inspired by proven research directions:

- memory-map weights rather than eagerly copying all weights;
- stream cold weights/experts from flash;
- prefetch likely active neurons/experts;
- keep hot neuron/expert clusters in a segmented cache;
- use large contiguous reads;
- schedule compute + I/O together;
- preserve a small resident working set.

Apple’s “LLM in a Flash” showed hardware-aware flash streaming can run models larger than available DRAM by windowing/reusing active neurons and row/column bundling. PowerInfer-2 demonstrated smartphone inference for a model exceeding memory by scheduling neuron clusters across compute and storage. These are inspiration for an **optional research runtime**, not proof that the same headline numbers apply to iPhone 12.

### D. MoE expert streaming

For sparse MoE models, investigate keeping only frequently used experts/resident tensors hot while inactive experts live in flash-backed storage.

A model with low active parameters is especially interesting if NovaForge can avoid requiring all experts resident simultaneously.

Do not claim this works until the exact architecture/runtime supports safe selective loading.

### E. Prompt/KV reuse

For repeated mission turns, avoid paying full prefill repeatedly when exact reusable prefixes exist.

Investigate:

- stable system/tool prefix caching;
- Project Brain prefix snapshots;
- durable or reloadable KV/session cache where runtime semantics make it safe;
- invalidation keyed to exact model/template/tool/schema revision.

Never restore incompatible KV state across changed model/tokenizer/template authority.

---

## 9. Project Brain compaction — stop using raw chat as memory

The biggest context optimization is architectural: **do not keep feeding the whole conversation back to the model.**

Project Brain should maintain typed compact state such as:

- product intent;
- Mission Constitution;
- current stage graph;
- accepted decisions;
- protected Design DNA;
- current file/symbol map;
- dependency graph;
- accepted test receipts;
- current defects/blockers;
- runtime capabilities;
- latest visual acceptance observations;
- concise checkpoint delta;
- known limitations.

### Project Capsules

At each durable checkpoint build a compact **Project Capsule** containing only the minimum authoritative state required to resume.

A capsule should be:

- source/revision bound;
- deterministic where practical;
- structured before prose;
- independently size-budgeted;
- retrieval-addressable;
- invalidated when source authority changes;
- cheap enough for tiny local models to consume.

### Hierarchical context

Use a tiered context system:

**L0 — Always resident**  
mission identity, current task, current stage, safety/privacy/model policy.

**L1 — Active working set**  
relevant files/symbols/diffs/test failures and recent decisions.

**L2 — Project memory**  
retrieved Project Brain facts, Design DNA, prior accepted checkpoints.

**L3 — Cold archive**  
old transcripts/logs/full diffs/screenshots available only by retrieval.

This allows long missions without pretending the model has infinite context.

### Compaction must be reversible enough for truth

Do not allow a summary model to silently erase:

- unresolved decisions;
- failing tests;
- security/privacy constraints;
- accepted user requirements;
- exact IDs/revisions needed for recovery;
- known limitations.

Critical structured truth is stored directly, not trusted to free-form summarization.

---

## 10. Model Arena becomes an engineering qualification lab

The Local Model Center should continuously qualify new models/runtimes through reproducible suites.

For each exact device/model/quant/runtime/context profile measure:

- cold load time;
- peak/resident memory;
- prompt processing speed;
- decode speed;
- energy/thermal behavior;
- context scaling;
- tool-call validity;
- edit correctness;
- multi-file task success;
- test-repair success;
- autonomous-loop stability;
- structured-output reliability;
- local-only network audit.

Include an **iPhone 12 compatibility lab** as a conservative baseline, but never label policy assumptions as measured hardware results.

Promote models based on the actual NovaForge task suite, not generic leaderboard hype.

---

## 11. Speculative and multi-model acceleration

Investigate fast local decoding architectures:

- tiny draft model + larger verifier;
- model-native MTP/speculative heads where supported;
- router selects tiny model for easy edits and deep model only for hard steps;
- precompute retrieval/compaction while coder model is decoding when safe;
- batch independent analysis tasks when thermal/memory policy permits.

The user should feel one coherent agent even if multiple local models cooperate underneath.

---

## 12. Device-aware Runtime Governor

NovaForge needs a runtime governor that reacts to actual device conditions.

Inputs may include:

- available memory / memory pressure;
- thermal state;
- battery/charging state;
- foreground/background state;
- model working-set estimate;
- active context/KV size;
- task urgency/depth;
- user performance/privacy preferences.

It can automatically choose:

- model tier;
- quant profile;
- context budget;
- KV precision;
- GPU/CPU/Metal balance;
- speculative decoding on/off;
- max autonomous parallelism;
- pause/retry after thermal pressure.

Never hide a forced cloud fallback behind the governor.

---

## 13. “Beyond ChatGPT-level” means a different product advantage

Do not interpret the target as copying ChatGPT visuals.

NovaForge should exceed a generic chat product specifically in **software creation workflow**:

- project-aware Composer;
- beautiful Plan Space instead of interrogation chat;
- durable autonomous missions;
- real runnable generated apps/games;
- self-play and runtime verification;
- visual picker and direct manipulation;
- Design DNA and protected design rules;
- History/visual time machine;
- exact local model/device intelligence;
- local-only creation;
- evidence-backed “Complete” state.

A gorgeous shell around a weak coding loop fails.
A brilliant agent behind generic card soup also fails.
Both product intelligence and presentation must close.

---

## 14. Visual acceptance for the Composer and Full Forge

The Composer/Plan Space/mission experience is a flagship visual gate.

Required states include at minimum:

- empty/new user;
- active project;
- local model loading;
- local model ready;
- local model memory pressure;
- Full Forge running;
- material decision required;
- build/test failure;
- runtime playtest;
- visual critique/repair;
- paused/interrupted;
- completed with evidence;
- completed with known limitations;
- offline/local-only;
- large Dynamic Type;
- Reduce Motion/Transparency.

The normal screen must not resemble a debug console, GitHub dashboard, or endless chat transcript.

---

## 15. Release gates for autonomous creation

Do not call Full Forge complete until a representative end-to-end suite proves:

1. user describes a new project from a clean state;
2. Plan Space resolves material decisions or delegates them explicitly;
3. a durable mission is created;
4. local model path remains local when local-only is selected;
5. project is generated/edited;
6. project builds;
7. project runs in canonical Forge Runtime;
8. autonomous tester interacts with it;
9. at least one seeded intentional defect is detected and repaired;
10. screenshot/visual review occurs;
11. relevant accessibility/performance gates run;
12. app/relaunch interruption can resume safely;
13. final Complete state points to exact accepted evidence;
14. History can show the accepted evolution/checkpoint lineage.

The flagship demonstration should include at least one small 2D game and one simple utility/app experience.

---

## 16. Research backlog — high-value experiments

Workers may pursue these as isolated, measurable experiments without prematurely making them production defaults:

- iPhone Metal implementation/benchmark of extreme KV compression such as TurboQuant-class methods;
- adaptive per-token KV bit allocation;
- BitNet ARM/iOS integration and coding/tool fine-tunes;
- flash-backed expert streaming for MoE on iOS;
- Apple-style windowed neuron loading on supported architectures;
- PowerInfer-2-inspired neuron-cluster scheduler for CPU/GPU/Metal + flash;
- persistent exact-prefix/KV cache across mission turns;
- AST/symbol-aware code context packing;
- screenshot-to-source visual defect localization;
- tiny specialist visual/log/test critic models;
- self-play coverage scoring for generated games;
- model/router policies that maximize task-success-per-joule rather than raw tokens/s.

Every experiment needs a truth boundary and exact device/runtime evidence before product promotion.

---

## 17. Worker priority rule from this document

When live GitHub shows the underlying foundations are sufficiently trustworthy, workers should aggressively climb into:

1. Local Model Fabric + exact-device qualification;
2. Forge Compact / Project Capsule compaction;
3. flagship Composer + Plan Space;
4. durable Full Forge autonomy loop;
5. Forge Runtime self-play/playtest bridge;
6. autonomous defect repair;
7. final visual/accessibility/performance closure.

Do not spend months creating isolated packages while the actual user cannot describe a game and watch NovaForge finish it.

**The target is a real creation machine, not an impressive architecture diagram.**

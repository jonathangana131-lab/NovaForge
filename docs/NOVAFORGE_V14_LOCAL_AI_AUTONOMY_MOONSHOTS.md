# NovaForge V14 — Local AI Autonomy / Low-Memory Moonshots

Status: PRODUCT DIRECTION + EXPERIMENTAL RUNTIME RESEARCH TRACK
Protocol: NF-SWARM-v14
Target baseline: iPhone 12 / iOS 27 unless a capability explicitly requires newer hardware

## North star

NovaForge should become an autonomous pocket software studio, not merely a chat screen that can edit files.

The normal experience should be:

**Describe -> Plan -> Build -> Run -> Play/Use -> Observe -> Improve -> Verify -> Complete**

A user should be able to describe an app or game, choose an autonomy level, and let NovaForge keep iterating until the product satisfies explicit completion gates. For games, NovaForge should be able to launch the generated project, operate its controls, play representative runs, inspect screenshots/runtime state, detect defects, patch the project, and repeat.

Local models are a first-class product pillar. Cloud providers remain optional acceleration/quality routes, never a requirement for the core local-first experience when the selected capability is advertised as local.

Do not fake completion. `Complete` is earned from evidence.

---

## 1. Composer / Plan Space should feel like a creation instrument

The composer is the front door to the entire product and must receive flagship-level design attention.

Avoid a generic chatbot text box with a row of settings chips. Aim for an original, calm, precise creation surface.

### Proposed interaction model

One primary creation field starts as a minimal invitation such as `What do you want to make?`.

As intent becomes richer, the composer can morph into an **Intent Canvas** rather than opening a settings form. The canvas may progressively reveal only what matters:

- a visual reference strip for images/screenshots/sketches;
- a compact project scope identity;
- an autonomy control: `Guide me`, `Build with me`, `Autonomous Studio`;
- a build-depth control that becomes visible only for complex work;
- a local-model status / model recommendation when it materially affects feasibility;
- one clear primary action that morphs from Describe -> Plan -> Forge -> Resume.

### Plan Space

Plan Space should brainstorm with the user, not interrogate them with a questionnaire.

It should:
- ask only material questions;
- generate visual previews/choice cards when a visual decision is easier to see than describe;
- support `Decide for me` without silently pretending a decision was user-authored;
- identify unknowns, risks, and acceptance goals;
- turn the resulting intent into an editable Mission Constitution;
- preserve the user's exact product promise, protected design decisions, and `Never do this again` rules in Design DNA;
- show the planned creation as a living composition, not a wall of markdown.

The visual target is beyond a conventional AI-chat composer: the feeling should be closer to a first-party iOS creation instrument where controls appear at the moment they become useful and disappear when they are not.

---

## 2. Autonomous Studio mode

`Autonomous Studio` is a first-class mission mode, not a marketing label.

A mission may keep working without asking the user after every step only inside explicit granted authority and safety/product boundaries.

Canonical loop:

`UNDERSTAND -> PLAN -> EDIT -> BUILD -> RUN -> OBSERVE -> TEST/PLAY -> CRITIQUE -> PATCH -> RE-RUN -> VERIFY -> POLISH -> COMPLETE`

### Required autonomous behaviors

- maintain durable mission checkpoints independent of raw chat history;
- recover after app/provider/model interruption;
- select the cheapest/fastest capable local model for each subtask when possible;
- escalate to a stronger installed model only when the task requires it;
- compile/lint/test immediately after meaningful code mutations;
- inspect actual runtime output rather than trusting generated source;
- preserve rollback points before risky migrations/refactors;
- keep failures and unresolved limitations visible;
- stop and ask the user only when a real user decision/permission is required.

### Compound tools for small local models

Small models should not be forced to maintain coherence across unnecessarily long chains of primitive calls.

Add high-level, auditable compound operations such as:
- `inspect_symbol_and_context`;
- `edit_then_compile`;
- `fix_build_errors`;
- `launch_and_capture_state`;
- `run_game_episode`;
- `compare_visual_before_after`;
- `checkpoint_and_compact`.

Internally, these can remain composed from secure primitives. The model receives a simpler decision surface while NovaForge preserves exact receipts underneath.

---

## 3. Game Auto-Player / Ghost QA

For Forge Runtime games, NovaForge should eventually act as its own QA player.

### Ghost Player

Build a deterministic/runtime-aware **Ghost Player** that can drive generated games through the same semantic control definitions the game exposes to real touch/controller input.

Prefer semantic controls and runtime state where available; use screenshot/vision reasoning as an observation channel, not as the only source of truth.

Potential player profiles:
- first-time player;
- ordinary player;
- chaotic input / edge-case player;
- speed-run / objective-seeking player;
- pause/resume/background/relaunch player;
- accessibility-oriented player using alternate controls.

### What it verifies

For representative projects, autonomous completion should be able to prove things such as:
- launch succeeds;
- no immediate crash/runtime exception;
- primary controls are reachable and actually work;
- player can make progress;
- a defined objective/win loop is reachable when the game has one;
- restart/reset behaves correctly;
- pause/resume does not corrupt state;
- save/relaunch restores accepted state where promised;
- orientation/safe-area behavior is usable;
- overlays do not hide critical controls;
- no obvious soft-lock/stuck state across bounded episodes;
- frame pacing/memory stay inside accepted measured budgets;
- screenshots pass visual hierarchy/contrast/clipping acceptance;
- generated sound/haptics do not fire nonsensically;
- runtime errors are fed back into the mission automatically.

### Completion pressure

One successful episode is not proof of a polished game.

A flagship autonomous game mission should run a bounded matrix of deterministic seeds/scenarios and continue fixing defects until the agreed completion gates pass or a real blocker is reached.

Do not create an infinite self-improvement loop. Every autonomous mission needs time/iteration/resource budgets, evidence-based stop conditions, and a durable explanation when it cannot earn `Complete`.

---

## 4. Forge Compaction Engine — make small models act bigger

The main long-mission problem is not only model intelligence; it is wasting context on information NovaForge already knows.

NovaForge should build a purpose-designed **Forge Compaction Engine** so local models operate on the smallest high-authority working set possible.

### Memory tiers

#### Tier A — Hot Working Set
Only the current goal, exact relevant code symbols, failing diagnostics, active decisions, and current tool contract.

#### Tier B — Mission Capsule
A compact validated state containing:
- mission goal;
- current stage;
- accepted decisions;
- unresolved blockers;
- exact changed files/symbols;
- test/runtime evidence;
- next safe actions;
- current model/route/tool authority.

#### Tier C — Project Graph / Project Brain
Durable indexed project knowledge:
- source symbols and dependencies;
- asset/runtime identity;
- Design DNA;
- protected decisions;
- accepted architecture facts;
- current capabilities;
- history/checkpoints;
- known defects and accepted limitations.

#### Tier D — Cold Evidence
Full diffs, logs, screenshots, build receipts, run histories, raw tool outputs and old context remain retrievable but are not carried in every prompt.

### Verified compaction

Compaction must never silently rewrite project truth.

A compacted Mission Capsule should be mechanically cross-checkable against authoritative state. Important facts retain source IDs / checkpoint IDs / symbol anchors / receipt references so a later worker can rehydrate exact evidence.

### Semantic delta compaction

Do not repeatedly summarize the whole mission. Compact only what changed since the previous accepted capsule:
- changed decisions;
- new source mutations;
- new errors/fixes;
- new runtime observations;
- new visual acceptance results;
- new Design DNA facts.

### Surgical rehydration

Before a model sees a giant file/repository dump, retrieve the smallest exact source slice needed for the current decision. Prefer AST/symbol/dependency-aware retrieval and recent diff context over blind character windows.

### Tool-schema compaction

For fixed NovaForge toolsets, investigate moving frequently repeated tool knowledge out of prompts through specialized local adapters/fine-tuning or compact grammar schemas, while preserving exact runtime validation. Recent research has shown that tool knowledge can sometimes be internalized into small models and substantially reduce prompt overhead; treat this as a lab track until NovaForge-specific evaluation proves it.

---

## 5. Local Model Runtime tiers

The Local Model Center should stop thinking only in terms of `model name + parameter count`.

It should reason about:
- total resident weight bytes;
- active parameters per token;
- weight representation / quantization method;
- KV-cache format and expected growth;
- context requirement for the current mission stage;
- peak measured memory on this exact device;
- time-to-first-token;
- decode throughput;
- thermal state;
- battery policy;
- tool-call / code-edit reliability;
- installed storage footprint;
- runtime/backend support.

### Suggested runtime classes

#### Instant Brain
Tiny always-available model for routing, compaction, classification, short edits, tool selection, and critics.

Candidate research families include sub-4B Qwen-class models, very small Bonsai/BitNet-class models, and future purpose-trained NovaForge micro-models.

#### Builder Brain
Best quality model that can stay reliably resident for meaningful coding/editing on the device.

On iPhone 12 this may be a highly compressed ~2B-8B-class model depending on measured runtime overhead/context. Do not publish a compatibility badge from weight size alone.

#### Stretch Brain — experimental
A model that does not fit comfortably under ordinary resident inference but may become usable through extreme low-bit weights, reduced/quantized KV, memory mapping, sparse/MoE expert paging, aggressive context compaction, or other measured techniques.

Stretch mode must be opt-in, clearly labeled experimental, and automatically back off before iOS kills the process.

#### External Brain
Optional trusted cloud/Mac provider for tasks the user authorizes. Local-only missions never silently enter this tier.

---

## 6. Current low-memory research worth prototyping

These are research/experimental leads, not promises of iPhone 12 production support.

### End-to-end 1-bit / ternary weights

- Microsoft `bitnet.cpp` provides official optimized inference for BitNet b1.58 models, including ARM kernels. Its official BitNet-b1.58-2B-4T is 2.4B parameters.
- PrismML's Bonsai family exposes 1-bit and ternary local models in GGUF/MLX forms. PrismML reports 8B/4B/1.7B low-bit families and in July 2026 announced a 27B 1-bit model at 3.9GB intended for newer phone-class hardware.

NovaForge opportunity: build a backend capability layer that can select ordinary GGUF/MLX quantization or true low-bit kernels rather than assuming every model is a conventional 4-bit transformer.

Important: a 3.9GB weight file does **not** mean a 4GB iPhone 12 can safely run it. Runtime/KV/app/system headroom must be physically measured.

### KV-cache compression

Long context can consume as much or more memory than model weights. Prototype multiple cache modes:
- existing llama.cpp low-bit K/V cache formats;
- recent-token high-precision tail + older low-bit cache;
- mixed/adaptive bit allocation;
- experimental 2-3 bit vector quantization inspired by VecInfer/TurboQuant;
- mission-specific cache budgeting instead of one maximum context for every task.

Google Research's TurboQuant reports large KV compression without retraining; 2026 work such as VecInfer and KVmix explores 2-bit/mixed-precision cache compression. These need an Apple/Metal implementation and NovaForge code/tool-use validation before product use.

### Persistent / reloadable agent KV

Research in 2026 has demonstrated persisting quantized KV caches for multiple edge agents and restoring them without full re-prefill.

NovaForge opportunity: investigate a **Mission Cache Vault** where suspended local sub-agents can persist compressed attention state to storage, then restore when the mission returns to that specialist. This is especially interesting for multi-agent local workflows where keeping every context resident is impossible.

Do not rely on this until output equivalence/quality and storage/security behavior are measured on the actual runtime.

### Weight mmap / demand paging

llama.cpp already uses memory-mapped model files by default, allowing static weight pages to be faulted in on demand instead of eagerly copying the entire file.

NovaForge can measure device-specific resident-set behavior and choose mmap/locking policies intelligently. Do not market `model larger than RAM` merely because mmap lets the address space open the file; random page churn can make it unusably slow or trigger memory pressure.

### MoE expert paging / partial residency

A 2026 llama.cpp proof-of-concept demonstrates paging Mixture-of-Experts weights from disk into a limited expert-slot pool, including a Qwen3 30B-A3B test on an M1 Pro with 16GB RAM.

NovaForge opportunity: experimental `Expert Streaming` backend for sparse models where only routed experts are resident. This could eventually let total model capacity exceed normal resident memory.

This is a research lane, not evidence that it works acceptably on iPhone 12. iPhone storage latency, memory pressure, thermal behavior, Metal synchronization, and iOS process limits must be measured.

### Mixed-bit per-layer weights

Recent MLX-LM experiments propose per-layer mixed-bit recipes rather than uniform quantization and report major decode improvements on Mac-class Apple Silicon.

NovaForge opportunity: generate/install device-specific quantization recipes based on sensitivity and measured code/tool quality rather than offering only `Q4/Q5/Q8` labels.

### Speculative decoding

Use a tiny fast local draft model to propose tokens and a stronger local model to verify them when the backend supports exact draft/verify semantics.

For NovaForge, the tiny model may also handle routing/compaction while acting as the draft model, increasing value from one resident micro-model.

### NovaForge-specific adapters

A small model that already knows NovaForge's stable tool grammar, project manifest, common edit protocol, and game/runtime contracts may outperform a larger generic model forced to reread those definitions every turn.

Investigate signed, version-matched adapters/fine-tunes for:
- tool routing;
- source edit planning;
- build-error repair;
- mission compaction;
- game QA planning;
- screenshot defect classification.

Never let an adapter bypass tool authorization or source-of-truth validation.

---

## 7. Model Center should be a live compatibility lab

The Model Center should feel like a serious local-AI control surface, not a download list.

For every model/variant/backend combination, NovaForge should be able to show **measured** or clearly **unmeasured** status for the current device.

Possible evidence card:
- Fits reliably: YES / NO / EXPERIMENTAL / UNMEASURED
- Peak resident memory
- Weight/storage bytes
- Context used during test
- KV mode
- Time to first token
- Decode tok/s
- Thermal state / throttling observed
- Tool-call correctness micro-suite
- code-edit/compile-repair score
- long-mission stability
- local-only verification
- battery policy

### Continuously fresh catalog

Support a signed metadata/catalog layer so new model families and runtime formats can appear without an app rewrite, while keeping model execution support gated by actual bundled/runtime capability.

A live model appearing on the internet does not automatically become `SUPPORTED`.

### Three install modes

- **Recommended** — proven stable on this device.
- **Aggressive** — lower-bit/longer-context tradeoffs with measured warnings.
- **Lab** — experimental inference techniques such as 1-bit kernels, ultra-low-bit KV, MoE paging, or new architectures.

---

## 8. Autonomous completion gates

NovaForge should never mark a generated app/game complete merely because the model said `done` or the project compiled.

Depending on project type, `Complete` may require a closure matrix such as:

### Engineering
- clean build;
- critical tests pass;
- no known fatal runtime errors;
- persistence contract exercised;
- migration/relaunch behavior exercised when promised.

### Runtime
- launch succeeds from a clean state;
- primary flow is usable;
- representative interaction episodes succeed;
- bounded error/crash loop stays clean;
- resource/runtime permissions match declared capability.

### Game self-play
- controls mapped and responsive;
- representative objective reachable;
- no obvious soft-lock across bounded scenarios;
- restart/pause/save behavior accepted;
- edge-case player episodes run.

### Visual
- screenshot matrix;
- no obvious clipping/overlap;
- hierarchy passes visual critique;
- loading/error/empty states designed;
- project does not look like an untouched generic template.

### Accessibility
- touch targets;
- VoiceOver semantics where relevant;
- Dynamic Type for generated UI apps where relevant;
- Reduce Motion/Transparency behavior when applicable.

### Performance
- measured frame pacing / memory appropriate to the project;
- no unsupported FPS claim;
- thermal/device claims remain evidence-bound.

A user can choose faster/lower closure depth, but NovaForge must label what was and was not verified.

---

## 9. New flagship concepts

Names are working concepts; workers should improve them rather than treating naming as immutable architecture.

- **Intent Canvas** — composer that grows only as intent needs structure.
- **Autonomous Studio** — user-authorized long-run build mode.
- **Forge Director** — mission-level planner/closure captain coordinating specialist models/tools.
- **Forge Compaction Engine** — validated multi-tier context system.
- **Mission Capsule** — tiny durable high-authority working context.
- **Ghost Player** — autonomous generated-game interaction/QA runner.
- **Visual Judge** — screenshot/runtime visual critic bound to objective checks + Design DNA.
- **Model Pilot** — per-stage model/router choosing the cheapest capable local brain.
- **Mission Cache Vault** — experimental persisted compressed KV/session state.
- **Stretch Brain** — opt-in experimental inference beyond ordinary resident limits.
- **Compatibility Lab** — exact-device model/runtime benchmark and qualification system.

---

## 10. Acceptance discipline for moonshots

Novel is not automatically good.

Every experimental runtime technique must answer:
1. Does it actually reduce peak resident memory on the target device?
2. What quality changes on coding/tool-use tasks?
3. Does it improve or destroy time-to-first-token / decode speed?
4. What happens under long context?
5. What happens under iOS memory pressure / thermal throttling?
6. Can output/evidence be reproduced?
7. Does it preserve local-only/privacy guarantees?
8. Is failure clean and recoverable?

If a clever technique performs worse than the simpler runtime, delete it or keep it in Lab only.

No benchmark theater. No fake `27B on iPhone 12` badge from compressed file size. No claiming an autonomous game is complete until the runtime/player/visual closure gates actually prove it.

---

## Research leads captured August 2026

These are external research/product leads to evaluate, not dependencies or endorsements:

- Microsoft bitnet.cpp — https://github.com/microsoft/BitNet
- PrismML Bonsai 1-bit/ternary family — https://prismml.com/news/bonsai-8b
- PrismML Bonsai 27B announcement — https://prismml.com/news/bonsai-27b
- Google Research TurboQuant — https://research.google/blog/turboquant-redefining-ai-efficiency-with-extreme-compression/
- VecInfer (ACL 2026) — https://aclanthology.org/2026.acl-long.1454/
- llama.cpp MoE on-demand expert paging PoC — https://github.com/ggml-org/llama.cpp/discussions/23324
- llama.cpp runtime low-bit KV/mmap capabilities — https://github.com/ggml-org/llama.cpp/blob/master/tools/cli/README.md
- MLX-LM mixed-bit decode optimization proposal — https://github.com/ml-explore/mlx-lm/issues/1450
- Qwen3-Coder-Next technical report — https://arxiv.org/abs/2603.00729
- JetBrains Mellum2 (12B total / 2.5B active code-focused MoE) — https://huggingface.co/blog/JetBrains/mellum2-launch
- Cohere North Mini Code (30B total / 3B active coding MoE) — https://huggingface.co/blog/CohereLabs/introducing-north-mini-code

Workers must re-check current upstream status before implementing around any external project because APIs/models change quickly.

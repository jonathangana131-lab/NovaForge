# NovaForge v13 Product Constitution

**Protocol:** NF-SWARM-v13  
**Codename:** iPhone AI Creation OS / Extreme Product Reinvention  
**Target generation:** NovaForge 2.0  
**Baseline:** iPhone 12 / iOS 27  
**Authority:** This document supersedes older product-direction assumptions in NF-SWARM v1/v2. Live technical truth still comes from current code/tests/GitHub.

## Prime directive

Build NovaForge into the best general-purpose AI coding agent and personal software creation environment that can realistically exist on iPhone.

NovaForge is not primarily a GitHub client, CI dashboard, terminal wrapper, generic chatbot, or desktop IDE squeezed onto a phone. Git, GitHub, Xcode, terminals, and external workers are optional advanced capabilities.

NovaForge is an iPhone-native AI creation environment where a normal user can describe an app or game, let a serious coding agent build it, run the supported creation full-screen on the phone, and iterate in seconds. Advanced users can inspect source, diffs, tests, providers, models, receipts, Git, and external execution environments without forcing that complexity on everyone else.

**Core public loop:** `DESCRIBE IT -> BUILD IT -> RUN IT -> IMPROVE IT`.

The deepest architectural rule is: **a project mission belongs to NovaForge, not to whichever model conversation happened to start it.** Models and execution environments are workers under one durable mission.

## Quality floor

Quality is not negotiable.

- A feature that technically works but looks unfinished is unfinished.
- A beautiful feature that lies about capability is unfinished.
- A sophisticated architecture that never reaches the user is unfinished.
- A fast implementation that is fragile, janky, inaccessible, or untrustworthy is unfinished.
- Optimize wasted effort, duplication, ceremony, and blocking. Never optimize by lowering truth, visual quality, accessibility, performance, safety, or verification.

## Controlled generational rewrite

The current app predates the present SOL-quality engineering model. V13 explicitly allows a controlled generational rewrite.

Preserve validated provider transports, useful AgentHarnessKit/domain/policy work, secure credential handling, durable user data worth migrating, proven llama.cpp local inference, strong tests, and any architecture that remains clean.

Replace or refactor obsolete presentation architecture, giant root views, brittle global state, duplicated agent truth, debug-style user surfaces, and historical assumptions that Git/repository management must be the primary product.

Legacy code is not sacred. Useful user data should migrate forward; bad internal architecture does not deserve compatibility merely because it exists.

Do not create a dead multi-month rewrite branch. Replace the product in working, testable, reversible generations.

## Product shape

The exact navigation may evolve, but these product concepts must exist:

- **Home / My Apps:** projects feel like runnable creations, not folders.
- **Forge:** intent, Plan Space, model/agent controls, live mission, concise evidence.
- **Run:** full-screen execution of supported Forge projects.
- **Edit / Inspect:** contextual code, files, visual selection, diffs, diagnostics when wanted.
- **History:** checkpoints, receipts, before/after visuals, time machine.
- **Model Center:** local/cloud model selection, compatibility, benchmark, downloads.
- **Control:** privacy, execution environments, providers, advanced policy.

The default product should feel simpler than ChatGPT even though the internals are far more powerful.

## Visual identity and UI bar

Minimum bar: ChatGPT-level interaction polish, first-party Apple responsiveness/accessibility, Tesla/Stark-VARG-style information confidence and reduction, restrained Iron-Man/JARVIS-inspired precision/energy, synthesized into an original NovaForge identity.

This is inspiration, not copying. Do not clone layouts, trade dress, assets, proprietary graphics, or exact visual systems.

Desired visual DNA:

- deep black/graphite plus excellent adaptive light surfaces;
- razor-clean typography and bold status/numeric hierarchy;
- restrained energy accents;
- thin precise geometry;
- premium native depth;
- extremely low clutter;
- physically coherent motion;
- purposeful haptics;
- no gamer RGB;
- no neon HUD spam;
- no fake hologram theater;
- no card soup or pill soup;
- no giant dead headers;
- no debug logs in primary hierarchy;
- no generic AI-gradient design language.

Use iOS 27 fluid/native capabilities aggressively where they improve hierarchy and feel: Liquid Glass, matched/interactive transitions, spring motion, native sheets/menus, keyboard/focus behavior, haptics, Live Activities, Dynamic Island where useful, App Intents, Spotlight, widgets, orientation/safe-area adaptation, and accessibility environments.

Define a purposeful **NovaForge Glass** system rather than blurring every rectangle. At minimum distinguish ambient/background, elevated interactive controls, focused Forge/mission surfaces, and high-contrast execution surfaces. Every translucent material needs an excellent Reduce Transparency fallback.

ProMotion devices should feel ProMotion where appropriate; iPhone 12 remains baseline performance/quality target.

## Plan Space

Traditional markdown questionnaires are not the primary planning UX.

When a mission genuinely requires decisions, the Forge composer can fluidly transform into **Plan Space**. Questions appear as beautiful contextual controls: choices, sliders, ranges, A/B previews, orientation choices, visual variants, free text, and a prominent **Decide for me** path.

Ask only questions whose answers materially change the product. Do not interrogate users for information the agent can safely infer or revise later.

Where feasible, controls drive small truthful previews. Example: Minimal <-> Detailed changes a preview; Arcade <-> Simulation changes the proposed handling/experience; portrait/landscape shows a real layout concept.

Once enough is known, Plan Space collapses into a compact **Ready to Forge** summary and Build action. The transition from intent -> questions -> mission should become a signature NovaForge interaction.

## User-facing AI controls

Expose powerful behavior as understandable product controls rather than raw temperature/top-p/provider knobs.

### Forge Intelligence
`Fast -> Balanced -> Deep -> Extreme`

If a provider exposes real reasoning-effort controls, map truthfully. Otherwise adjust NovaForge's own planning, context, review, and verification strategy. Never claim provider reasoning support when absent.

### Build Depth
`Prototype -> Polished -> Obsessive / Go Crazy`

- Prototype: build, basic verification, runnable result.
- Polished: architecture, build, test, run, inspect, visual pass, repair, accessibility basics.
- Obsessive/Go Crazy: deep architecture, adversarial tests, runtime observation, visual critique, performance, edge cases, accessibility, repeated polish until meaningful improvement plateaus or the budget/user/dependency stops it.

### Creativity
`Faithful -> Inventive`

Inventive mode may propose complementary features while preserving the user's actual goal.

### Refactor risk
`Preserve -> Rebuild`

Controls willingness to replace poor legacy architecture after establishing migration/regression safety.

### Autonomy
`Ask -> Assist -> Build -> Autopilot`

Autonomy is a permission envelope, not personality.

### Compute/resource controls
Local: `Cool & Efficient -> Maximum Performance` subject to device/thermal truth. Hosted: `Efficient -> Maximum` with advanced cost/token detail available but not forced on normal users.

## Forge Pulse and live mission UI

Raw tool-call spam is not the primary experience.

The composer/primary action can transform into a compact **Forge Pulse** that communicates real mission state: Understanding, Planning, Editing, Running, Inspecting, Fixing, Polishing, Waiting for decision, Complete.

Tool activity becomes semantic micro-events: Edited 4 files, Built project, 23 tests passed, Inspecting preview, Repaired runtime crash. Exact commands/diffs/logs remain expandable for experts.

The primary action may morph spatially through `Send -> Plan -> Forge -> Pause -> Resume -> Run`.

A restrained original forge-line/energy motif may travel through active surfaces, intensify during work, qualify/break on failure, and resolve on acceptance. It must remain subtle, accessible, and never become fake sci-fi theater.

## Living mission engine

A plan is durable and dynamic, not frozen markdown.

Canonical loop:

`UNDERSTAND -> ASK ONLY MATERIAL QUESTIONS -> DESIGN -> IMPLEMENT -> RUN -> OBSERVE -> DIAGNOSE -> REPAIR -> TEST -> VISUAL CRITIQUE -> ACCESSIBILITY -> PERFORMANCE -> POLISH -> RETEST -> CHECKPOINT -> ASK WHAT IS STILL WEAK -> CONTINUE`

A compile is not completion when the request was to make an excellent app/game.

Mission stages can be inserted/reordered when evidence changes. The user can pause, resume, append instructions, reprioritize safe stages, defer optional work, or branch from a checkpoint.

Each substantial mission gets a **Mission Constitution** generated from user intent: functionality, runnability, design target, orientation, performance target, accessibility, persistence, explicit non-goals, constraints, and completion evidence. The agent may not silently redefine done.

## Long-run agent harness

NovaForge must support missions with hundreds of actions and potentially hours of elapsed work.

Required properties:

- durable mission state independent of transcript;
- structured project memory;
- checkpoints after meaningful accepted steps;
- cancellation without corruption;
- idempotent recovery;
- staged/atomic multi-file changes where appropriate;
- resumable tool sequences;
- exact receipts/provenance;
- model switching without mission loss;
- context compaction and retrieval;
- task graph;
- safe parallelism;
- independent verification;
- failure backoff/escalation;
- no ceremonial early stopping.

Do not persist hidden chain-of-thought. Persist user-visible reasoning summaries, decisions, plan state, evidence, and receipts.

## Structured Project Brain

Do not use a giant chat transcript as the project database.

Maintain source-backed structured knowledge: product intent, Design DNA, protected design choices, rejected anti-patterns, feature/architecture graphs, files/symbols, dependencies, runtime capabilities, tests, recent changes, accepted decisions, unresolved problems, performance evidence, model history, checkpoints, provenance, and staleness.

Use context virtualization: retrieve only the relevant neighborhood for each model/tool step instead of resending the whole project.

An advanced Memory Inspector can show fact, source/provenance, scope, last verified time, stale/current state, refresh, and forget. AI summaries never silently overwrite source truth.

## Intent Core and Design DNA

Each project should retain a concise human-readable Intent Core such as `Fast · Dark · Touch-first · Landscape · Realistic physics · No clutter`.

Design DNA can retain typography hierarchy, spacing rhythm, corner geometry, material strategy, icon weight, accent behavior, motion feel, interaction rules, protected components, and project-level anti-patterns.

Users can choose **Protect this design** or teach **Never do this again**. These are editable preferences, not permanent traps.

## Ghost builds / A-B / experimentation

Experimentation should be safe.

- **Ghost Build:** isolated candidate checkpoint; compare to current; Replace / Keep Current / Keep Both.
- **Parallel prototype race:** two bounded implementations run against the same tests/visual/performance evidence.
- **Visual A/B:** real variants users can swipe/run, not static hand-waving.
- **Plan branches:** compare simpler/faster vs more extensible approaches.
- Every accepted state remains recoverable enough that users can say `try something insane` without fearing permanent destruction.

## Forge Runtime

iOS does not permit NovaForge to arbitrarily compile/install/execute fresh unsigned native iOS code inside itself. Never pretend otherwise.

NovaForge therefore needs a first-class **Forge Runtime** for project formats safely executable in the host app.

Initial priorities: HTML, CSS, JavaScript, Canvas, WebGL, curated runtime libraries, safe local assets, sandboxed storage, and controlled host capability bridges.

Supported projects must not feel like a debug WebView. They should support full-screen launch, icon, splash/launch experience, portrait, landscape, auto/mixed orientation where feasible, safe areas, touch/multitouch, keyboard, audio, local saves, explicit haptic bridge, game controller, share/export bridge, runtime diagnostics, crash capture, and safe live reload.

Run is sacred: edit -> tap Run -> creation immediately fills the screen. Return to Forge quickly, change, Run again.

Native Swift projects remain valid advanced projects, but actual native compilation/signing requires a legitimate external Xcode/Mac execution environment.

## Curated creation kits

Build reusable curated runtime capabilities so models do not reinvent every foundation.

- **UI App Kit:** navigation, controls, sheets, inputs, lists/grids, charts, local persistence, responsive layout, themes, haptics.
- **2D Game Kit:** deterministic loop, sprites, collision/physics helpers, camera, touch, audio, particles, save, pause, controller mapping.
- **3D Forge Kit:** WebGL/Three.js-style scenes, camera, touch joystick, controller input, curated physics, entities, materials/assets, performance budgets, orientation, pause/settings.

Present these to normal users as capabilities such as `3D Scene + Touch Controls + Local Save + Haptics`, not dependency-manager jargon.

## My Apps

Projects should feel like creations, not repositories. My Apps can show the project icon, name, real latest runtime thumbnail, run state, local/offline status, and last changed time. Tap to open/run. Long press for Edit, Duplicate, Remix, Export, Share, Details.

Project cards should use real latest runtime screenshots when available rather than fake concept art.

## Direct manipulation

- **Visual Picker:** select DOM/UI element in a running project and Edit with NovaForge.
- **Game Inspector:** select scene/HUD object and connect it to source/runtime identity.
- **Physics Playground:** live tune exposed values such as gravity, mass, friction, damping, steering, torque, suspension, camera FOV, then Keep These Values writes them cleanly.
- **Talk while pointing:** select an object then issue a voice instruction.
- **Screenshot annotation:** draw/circle/write on a runtime image and attach structural context.
- **Record a problem:** short interaction/video plus runtime logs/timeline for diagnosis where supported.

## Agent observes its own product

For supported Forge projects, the agent should be able to launch, capture screenshots, inspect DOM/scene/runtime structure, capture console/runtime errors, inspect measured performance, interact through deterministic test harnesses, compare visual baselines, critique, repair, and rerun.

Visual loop: `IMPLEMENT -> RUN -> INTERACT -> CAPTURE -> CRITIQUE -> FIX -> COMPARE -> PROFILE -> ACCESSIBILITY -> REPEAT`.

**Auto-Polish** can repeatedly find the weakest meaningful visible defect and improve it until improvement plateaus, budget expires, a dependency blocks, or acceptance passes. Do not endlessly micro-polish while major product functionality is missing.

## Visual-quality automation

Generated projects should be checked for clipping, overlap, bad spacing, browser defaults, tiny touch targets, broken safe areas, huge dead areas, bad contrast, unreadable type, orientation failure, accidental scrolling, missing loading/error/empty states, ugly HUD placement, broken Reduce Motion/Dynamic Type where relevant, and confusing first-use behavior.

Use screenshot regression with intentional-change awareness. When motion matters, inspect frame sequences where supported rather than only a single screenshot.

Include a **first 60 seconds** quality test: is the creation immediately understandable, alive, usable, and not obviously unfinished?

## Crash Doctor

Runtime exceptions should be captured with exact stack/source association when possible, attached to the mission/checkpoint, summarized clearly, fed back to the agent, repaired, and relaunched. Do not make users manually copy console errors into chat just to continue.

## Performance intelligence

Advanced runtime HUD may show measured FPS, long frames, JS frame time, entity count, draw calls where available, asset stalls, and errors. Performance Coach acts on measurements, not vibes.

Generated games can tune render scale, shadows/effects, physics tick, entity counts, asset sizes, and battery/thermal sensitivity. Missions can target `great on my phone` or a device family such as `iPhone 12 and newer`.

## Model Center

Local models are a flagship product surface, not buried settings.

NovaForge already has llama.cpp roots. V13 expands this into a dynamic/updatable Model Center with recent compatible coding models, family, parameter count, quantization, context, tool/structured-output support, license/source, disk size, device compatibility, download/resume, validation, benchmark, observed quality profile, and storage controls.

Friendly compatibility labels may include Excellent, Good, Slow, Too Large, Untested, Unsupported, backed by explicit evidence/rules. Never present guesses as measured facts.

Users should not need to understand Q4_K_M to get a good recommendation; technical detail can expand.

## Local Model Compatibility Lab and benchmarks

For newly released models: inspect metadata/architecture, tokenizer/template, context, memory/disk requirements, tool/grammar support, run bounded smoke inference, and optionally run a coding micro-suite before promoting support.

Use background transfer architecture for large model downloads where appropriate.

Optional on-device benchmark can measure prompt processing, tokens/sec, stability, memory/thermal indicators where available, context/tool correctness, and bounded coding tasks.

A personal model leaderboard learns observed behavior on this device/project. Model Arena can run the same bounded task across multiple models and compare result/test evidence and latency.

## Model routing and multi-model team

Users can always lock a specific model. Auto may choose different models for retrieval, simple edits, architecture, visual critique, and review.

Internal roles can include Builder, Reviewer, Visual Director, Adversarial User, Performance Reviewer, and Simplicity Reviewer. The user sees one coherent mission, not six chats.

If a fast/local model repeatedly fails a blocker, NovaForge may propose a deeper/stronger route for that bounded step if policy allows.

## Privacy / local-only / hybrid

Private Mode / Local Only forbids silent hosted inference or network fallback. Hybrid mode can keep retrieval/summarization local and send only the minimum authorized context to cloud. Before hosted handoff, show what is being sent, e.g. `mission summary + 3 source files`.

Only show `100% On Device` when true. Supported Forge creation should work in airplane mode when required models/modules/assets are already local.

## Continuity Engine

NovaForge must continue useful user-initiated work as far as iOS legitimately permits.

Use current supported iOS continued-processing APIs for eligible long user-started work, background URLSession for large transfers where appropriate, durable checkpoints, Live Activity/system progress, and meaningful notifications.

Do not promise that the iPhone process runs forever while closed. iOS may terminate work; durable recovery is mandatory.

Live Activity should show meaningful stages such as `Building Neon Racer`, `Implementing vehicle physics`, `Testing`, `Needs decision`, `Complete`, not token spam.

## Cloud continuation and optional Mac Worker

If a real supported cloud execution service exists and the user enables it, the same durable mission may continue after the phone process dies. Phone becomes controller/status surface. Never claim this exists until the backend actually exists.

An optional paired Mac Worker may provide Xcode, xcodebuild, Simulator, native Swift compile/test, screenshots, profiling, signed device builds where legitimate, and filesystem/repo operations under policy. Forge Runtime projects remain useful without a Mac.

The same mission may hand off among local iPhone, cloud, and paired Mac workers without rebuilding context from chat.

Execution receipts must state where evidence came from. Simulator evidence is never physical-device evidence.

## Night Build / mission queue

A background mission queue can execute bounded tasks safely. Night Build can use legitimate on-device continued processing plus durable checkpointing and, where actually implemented/authorized, cloud or Mac workers. Never fake perpetual iPhone background execution.

Users can append instructions to a live mission and have them applied at a safe planning boundary.

## History / visual time machine

History should preserve mission intent, accepted decisions, source/checkpoint identity, changes, screenshots/preview, tests, runtime result, performance evidence, model/route, execution environment, known limitations, and continuation lineage.

A visual time machine should let users scrub meaningful project evolution and Restore / Fork / Compare. Branching can be presented as human language such as **Try another idea** without forcing Git vocabulary.

## Replayable tests and adversarial use

Users can record a safe semantic workflow such as `Launch -> Start Game -> Drive -> Pause -> Resume -> Garage` and turn it into a regression test.

Generated acceptance can cover functionality, visuals, orientation, persistence, crash/relaunch, accessibility, performance, and runtime.

Adversarial User intentionally tries double taps, rotation, interrupted loading, denied permissions, giant inputs, background/relaunch, pause/resume, and other realistic abuse.

## Direct user steering

Users can add instructions, reprioritize, pause/resume, defer optional features, adjust Build Depth, request alternate approaches, and take over source manually. Human edits become explicit project state; the agent must not blindly overwrite them.

## Mobile code editor

The expert editor should be genuinely good on iPhone: fast syntax highlighting, symbol/file search, fuzzy navigation, coding keyboard accessory, external keyboard support, semantic selection, diffs, errors, source-to-preview connections, and split preview where useful. Do not imitate a desktop IDE pixel-for-pixel.

## Universal command palette

Quick actions can include Run, Ask about this, Switch model, Open project, Undo agent change, Find file/symbol, Start visual critique, Pause/Resume mission, Inspect receipt, Open diagnostics. Expose through gesture/keyboard/Spotlight/App Intent where valuable.

## Voice / camera / sketch creation

Voice coding can create/steer missions. Camera-to-app/reference workflows can use vision models to extract design concepts while producing original implementations. Sketch Mode can turn rough hand-drawn boxes/labels into working UI.

## Asset Studio

Generated/user/imported assets retain provenance. Support icon/sprite/background/texture/simple illustration workflows, variation studio, duplicate/oversize/missing/unused detection, and quality-preserving optimization. Offline asset packs may exist where licensing permits.

## Safe host capabilities

Forge projects request curated host capabilities through explicit bridges and a permission manifest. Examples may include haptics, share sheet, local storage, file/photo picker, controller, and later legitimate permissioned sensors/media/network. Generated code never receives arbitrary native authority.

## Export / share / remix

Export source ZIP, Forge project package, web output where applicable, optional GitHub, or native Swift handoff to Mac/Xcode. Long-term Remix/community features can exist after core product quality, not before.

## Completion experience

A major mission can finish by collapsing Forge activity into the actual runnable creation, with a subtle real success haptic and `Ready`, not cheap confetti.

Completion report can show runnable result, changes, screenshots, tests, performance, evidence level, known limitations, and likely next improvements. `Show me why you think it's done` opens proof.

Evidence levels may distinguish Generated, Compiled, Runtime tested, Visually inspected, Simulator verified, Physical device verified, etc. Never blur these.

## Post-run follow-up / Learn Mode / personal software generator

After the user tries a project, offer evidence-informed next moves rather than only `How was it?`.

Optional Learn Mode explains selected implementation choices while normal Build stays concise.

Long-term **Build me something** mode can turn a mood/goal into a small personalized app/game, expanding NovaForge from coding app into personal software generator. Do not prioritize this ahead of core agent/runtime quality.

## Provider and route truth

Provider name is not a wire contract. Every supported route must bind provider, adapter, model, dialect, endpoint, auth, serializer, stream parser, tools, structured output, context/output limits, reasoning support, retry/cancel behavior, health, and support status.

Support states: SUPPORTED, EXPERIMENTAL, LEGACY, BROKEN, UNVERIFIED, REMOVED_DO_NOT_OFFER.

Only Supported is a normal recommendation. Private/undocumented ChatGPT backend use is not an ordinary supported consumer route without an explicit public contract. Public OpenAI API billing is separate from ChatGPT subscription. Local-only never silently falls back to hosted.

## Security / approvals / provenance

Model output cannot grant itself authority. Tools are typed, versioned, bounded, locality-known, cancellable where possible, and truthful about success/failure. Mutations obey explicit policy and approval. Secrets belong in Keychain and are excluded from receipts/logs. Prompt injection cannot grant authority. Exact project identity and path safety are mandatory.

Durable receipts capture mission/run identity, project, model/route, execution environment, plan/checkpoints, tools, approvals, changes, tests, runtime, screenshots, failures/retries, artifacts, result, and continuation lineage. Never persist hidden chain-of-thought or fabricate evidence.

## Architecture direction

Likely module boundaries include AppShell, ForgeProjects, ForgeMission, AgentCore, AgentPolicy, AgentTools, ModelCatalog, ModelRuntime, ProviderRuntime, ForgeRuntime, RuntimeBridge, ProjectStore, ProjectMemory, ProjectHistory, ProjectTesting, VisualQA, DesignSystem, ExecutionWorkers, and real optional Cloud/Mac bridges.

Names may change. Boundaries matter more than names.

Avoid 300 KB god views, giant environment objects, duplicate state ownership, excessive micro-protocol architecture, dead abstractions, and architecture astronautics. Choose the simplest structure that preserves truth, testability, performance, and the full product.

## Performance and accessibility

Measure launch, Forge responsiveness, composer latency, streaming, long histories, 100+ files, search, runtime start, live reload, local inference, memory pressure, model load/unload, thermal behavior, checkpoint/recovery, orientation, navigation, and long mission persistence.

Tap feedback must be immediate even when model work is slow. Streaming must not relayout huge conversation trees constantly.

Required accessibility includes VoiceOver, Dynamic Type, Reduce Motion, Reduce Transparency, Increase Contrast, Differentiate Without Color, 44pt targets, keyboard/external keyboard, focus, orientation, and truthful haptics.

## Creation challenge release gate

NovaForge 2.0 is not done until blank-project end-to-end missions can create and run representative projects including: polished utility, responsive dashboard, persisted-data app, touch-controlled 2D game, simple 3D driving/interactive experience, orientation-changing project, offline/local-model build, intentionally broken project repaired by NovaForge, visual-selection edit workflow, and long mission recovery after interruption.

Judge runnability, design, interaction, performance, persistence, repair, accessibility, agent truth, and user effort.

## Product-closure ladder

For every major capability: `DOMAIN/TRUTH -> INTEGRATION -> PERSISTENCE -> APP WIRING -> USER EXPERIENCE -> VISUAL/MOTION -> RUNTIME -> ACCESSIBILITY -> PERFORMANCE -> ADVERSARIAL TESTING -> FINAL POLISH`.

Do not perfect a 99% foundation forever while the product layer above it is weak unless the remaining foundation defect blocks correctness or safety. Do not confuse sophistication with progress.

## Future-generation rule

NovaForge must not become `finished forever`. Once this product generation genuinely closes, preserve a stable release and create a new master prompt for the next ambitious generation. Brainstorm new user value before coding rather than letting the app sit untouched or endlessly harden a frozen feature set.

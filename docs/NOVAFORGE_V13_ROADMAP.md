# NovaForge v13 Roadmap — NovaForge 2.0

This roadmap is intentionally ambitious. It is not a promise that every item ships in one release. It defines the product generation and the order in which workers should convert foundations into real user value.

## Guiding rule

Always climb toward a usable product:

`TRUTH/DOMAIN -> INTEGRATION -> PERSISTENCE -> APP WIRING -> UX -> VISUAL/MOTION -> RUNTIME -> ACCESSIBILITY -> PERFORMANCE -> ADVERSARIAL TESTING -> POLISH`.

Do not confuse sophistication with progress. Do not keep hardening mature internal foundations while the user-facing product remains weak unless the remaining internal defect blocks correctness/safety.

## Wave 0 — live-state stabilization

Before major rewrite integration, keep the current app usable and trustworthy.

- Finish or safely supersede PR #12 provider-reliability work based on exact live state.
- Preserve public provider contracts and eliminate ordinary selection of known-broken/private routes.
- Keep local model download/validation/recovery trustworthy.
- Keep CI/exact-head verification functional enough to protect product work.
- Do not let release-proof bureaucracy consume the rewrite program.
- Quarantine Voltline/foreign work.

**Exit:** current app can reliably reach supported provider/local routes and major migration work is not built on a broken execution core.

## Wave 1 — V13 scaffolding + migration map

- Establish V13 constitution/control docs and canonical prompt.
- Inventory current durable user data and settings.
- Inventory services/domain layers worth preserving.
- Identify legacy presentation monoliths and ownership seams.
- Define NovaForge 2.0 module boundaries.
- Add migration tests/fixtures before destructive structural changes.
- Establish a feature flag/controlled entry for the new shell if needed.
- Establish deterministic visual fixtures for the rewritten shell.

**Exit:** workers can rebuild product surfaces without guessing which old state must survive.

## Wave 2 — DesignSystem 2.0

Parallel-friendly lanes:

- NovaForge materials / Liquid Glass hierarchy;
- typography and spacing tokens;
- motion primitives;
- haptic semantics;
- primary Forge action morphing;
- accessibility fallbacks;
- reusable project/model/status components;
- Simulator screenshot fixture framework.

Do not build a giant component gallery and call it product progress. Components must land through real screens quickly.

**Exit:** rewritten surfaces have a coherent original visual language.

## Wave 3 — Home / My Apps 2.0

- Replace repository-centric landing assumptions.
- `What do you want to make?` primary creation entry.
- recent/active runnable creations with real previews;
- active mission continuation;
- create/new project flow requiring minimal technical setup;
- project long-press actions: Edit, Run, Duplicate, Remix, Export, Details;
- migration of existing projects into new visual library;
- startup performance and empty-state polish.

**Exit:** a normal user understands NovaForge without knowing Git.

## Wave 4 — Forge 2.0 / Plan Space

- Rewrite Forge shell/composer around durable mission state.
- Plan Space structured question model.
- Decide for me.
- Intelligence, Build Depth, Creativity, Refactor Risk, Autonomy controls.
- Forge Pulse semantic activity.
- expandable exact tool/diff evidence.
- interruption/steering UI.
- Mission Constitution display/edit.
- model picker / Auto mode integration.
- first-party motion/accessibility acceptance.

**Exit:** creating a mission feels magical, simple, and deterministic rather than like a developer chat wrapper.

## Wave 5 — durable Mission Engine / Project Brain

Potential parallel lanes:

- mission state machine;
- dynamic stage graph;
- mission checkpoint persistence;
- structured project memory;
- context virtualization/retrieval;
- provenance/staleness;
- model handoff;
- atomic/staged mutation semantics;
- user steering/reprioritization;
- recovery from provider/app interruption;
- mission queue.

**Exit:** a large mission can run for many steps, pause, relaunch, switch model, and continue without re-prompting from scratch.

## Wave 6 — Forge Runtime MVP

- versioned project manifest;
- sandboxed project identity/storage;
- HTML/CSS/JS runtime;
- Canvas/WebGL;
- curated module loading;
- full-screen Run mode;
- orientation and safe areas;
- audio/touch/multitouch;
- save storage;
- runtime error capture;
- launch/splash/project icon;
- return-to-Forge escape path;
- runtime screenshots;
- basic performance telemetry;
- safe live reload classification.

**Exit:** user can describe a small app/game and actually run it full-screen on iPhone.

## Wave 7 — UI App Kit + generated-app quality

- reusable responsive navigation/controls;
- storage/forms/charts;
- loading/error/empty states;
- design tokens for generated apps;
- generated project templates/capability scaffolding;
- first-60-seconds test;
- visual defect detector;
- screenshot regression;
- Auto-Polish MVP.

**Exit:** generated utilities stop looking like generic browser demos.

## Wave 8 — Direct visual editing

- stable DOM/source element identity;
- Visual Picker overlay;
- selected element -> agent context;
- Edit with NovaForge;
- screenshot annotation;
- voice while pointing;
- before/after visual acceptance;
- protected design markers;
- Design DNA persistence.

**Exit:** user can point at a running UI and change it without finding source files.

## Wave 9 — 2D Game Kit

- deterministic loop;
- sprite/scene lifecycle;
- collision/physics helpers;
- camera;
- touch-control framework;
- audio/particles;
- persistence;
- pause/settings;
- controller support;
- generated acceptance tests;
- performance budget.

**Exit:** NovaForge can reliably create a polished small touch game from a blank prompt.

## Wave 10 — 3D Forge Kit

- curated WebGL/Three.js-style scene stack;
- entity/source identity;
- cameras;
- touch joystick;
- controller mapping;
- curated physics integration;
- scene inspector;
- materials/assets;
- render/physics budgets;
- 3D project templates;
- deterministic test scenes;
- iPhone 12 profiling.

**Exit:** NovaForge can create a simple usable 3D driving/interactive experience that feels native to Run mode.

## Wave 11 — Game Inspector / Physics Playground

- select game object/HUD;
- source/config binding;
- live tune exposed properties;
- Handling / Power / Camera / Grip / Suspension concepts;
- Keep These Values -> clean source change;
- draggable touch controls;
- controller mapping UI;
- visual/runtime regression after tuning.

**Exit:** users can tune generated games by feel instead of editing constants manually.

## Wave 12 — Local Model Center 2.0

- new flagship model UI;
- dynamic catalog architecture;
- device compatibility evidence model;
- download/resume/background transfer;
- validation pipeline;
- storage intelligence;
- memory-pressure handling;
- local-only privacy surfaces;
- model recommendation UI;
- benchmark history.

**Exit:** users can confidently install and use current local coding models without learning GGUF internals.

## Wave 13 — Compatibility Lab / Model Arena

- metadata compatibility probes;
- tokenizer/template validation;
- tool/grammar capability tests;
- coding micro-suite;
- exact-device tok/s measurement;
- thermal/stability observation;
- personal leaderboard;
- Model Arena comparisons;
- per-project observed model suitability;
- Auto-routing input.

**Exit:** `best model for this phone/project` is grounded in actual evidence rather than static marketing.

## Wave 14 — Multi-model mission team

- Builder/Reviewer role orchestration;
- Visual Director;
- Performance/Simplicity reviewers;
- Adversarial User;
- bounded context disclosure by role;
- exact route receipts;
- compact one-mission UI;
- automatic escalation proposal on repeated failure.

**Exit:** multiple models improve quality without turning the UX into swarm management.

## Wave 15 — History / Ghost Builds / Time Machine

- immutable/efficient checkpoint lineage;
- visual checkpoint previews;
- scrub evolution;
- restore/fork/compare;
- Ghost Build isolated candidates;
- real A/B visual/runnable comparison;
- Try another idea language;
- history performance with many checkpoints.

**Exit:** experimentation feels safe and understandable without Git vocabulary.

## Wave 16 — recorded tests / autonomous QA

- semantic interaction recorder;
- Teach NovaForge This Workflow;
- replay engine;
- adversarial journey generation;
- orientation/background/permission tests;
- screenshot baselines;
- motion-frame inspection where justified;
- Auto-Polish iteration control;
- quality plateau/budget logic.

**Exit:** agents can prove generated projects still work after repeated improvement.

## Wave 17 — Asset Studio

- icon generation flow;
- asset provenance;
- variations / More Like This;
- import/user assets;
- duplicate/unused/missing analysis;
- image-size/texture optimization;
- offline licensed packs where appropriate;
- direct project insertion and runtime preview.

**Exit:** generated apps/games can gain coherent visual assets without leaving the creation loop.

## Wave 18 — Continuity Engine

- durable mission checkpoint under suspension/termination;
- eligible iOS continued-processing integration;
- cancellation/expiration correctness;
- Live Activity;
- notification policy;
- background model/asset transfer;
- resume after simulated/real interruption;
- state truth when work is no longer running.

**Exit:** leaving NovaForge does not casually destroy a long build, while the app remains honest about iOS limits.

## Wave 19 — optional Cloud Continuation

Only if a real supported backend exists.

- authenticated worker identity;
- mission/checkpoint sync;
- authorized project/context upload;
- policy/resource budgets;
- stale-result rejection;
- result receipt/provenance;
- Live Activity/status sync;
- privacy inspection.

**Exit:** true multi-hour remote continuation without pretending the iPhone process stayed alive.

## Wave 20 — optional Mac Worker

- pairing/trust model;
- capability/version advertisement;
- Xcode/xcodebuild integration;
- Simulator;
- native tests;
- screenshots;
- profiling;
- native device build/install where legitimate;
- same-mission handoff;
- exact environment receipts.

**Exit:** NovaForge can control serious native iOS work from iPhone while remaining fully useful for Forge projects without a Mac.

## Wave 21 — expert editor / native project workflow

- mobile syntax editor;
- symbol/file search;
- command palette;
- diff/error navigation;
- source-to-preview;
- external keyboard;
- Take Over conflict handling;
- optional Git status/commit/PR;
- native Swift project handoff.

**Exit:** advanced developers get real power without making the normal product feel like GitHub Mobile.

## Wave 22 — Voice / Camera / Sketch creation

- voice missions/steering;
- camera/reference import;
- sketch-to-UI;
- vision-backed visual interpretation;
- original-design constraints;
- direct preview and repair.

**Exit:** users can create or steer software through more than text.

## Wave 23 — export / share / remix

- source ZIP;
- Forge package;
- web export where appropriate;
- GitHub optional;
- native Xcode package;
- portable Remix package;
- permission/provenance preservation.

Community/gallery is future-only until the core is exceptional.

## Wave 24 — release-quality product closure

Mandatory closing work:

- first-party visual audit of every primary screen;
- iPhone 12 performance audit;
- ProMotion fluidity audit;
- Dynamic Type / VoiceOver / Reduce Motion / Reduce Transparency / Contrast;
- long mission stress;
- huge project/history stress;
- background interruption/recovery;
- model memory/thermal stress;
- provider failure matrix;
- crash doctor;
- runtime sandbox/security review;
- migration from old stores/settings/projects;
- creation challenge suite.

## Creation challenge suite

From blank projects, require end-to-end builds of at least:

1. polished calculator/utility;
2. responsive information dashboard;
3. persistent-data mini app;
4. touch-controlled 2D game;
5. simple 3D driving/interactive project;
6. project that changes orientation correctly;
7. fully offline local-model build with preinstalled resources;
8. intentionally broken runtime repaired by Crash Doctor;
9. visual selection/edit round-trip;
10. long mission that resumes after interruption.

Track user effort: NovaForge should perform the technical work, not force the user to become its QA engineer.

## Parallel worker starting lanes

When V13 begins, workers should prefer non-conflicting meaningful lanes such as:

- provider reliability closure (#12 lineage);
- rewrite/migration archaeology;
- DesignSystem 2.0 primitives + real screen integration;
- Plan Space domain model;
- Mission Engine durable state;
- Project Brain schema/retrieval;
- Forge Runtime manifest/sandbox research;
- Model Center architecture;
- visual QA fixture system;
- Home/My Apps product redesign;
- Forge screen product redesign;
- long-run recovery tests.

Before editing a high-contention production file, refresh current PR ownership.

## Progress reporting

When the user asks `novaforge progress`, report two views:

- **IN APP / INTEGRATED** — merged/current-main product value;
- **IN WORK / ACTIVE** — substantial tested active branch work.

Do not inflate completion from PR counts. Give partial credit based on implementation/testing/integration maturity. Physical-device/local-performance claims move only with appropriate evidence.

A useful status should include:

- overall integrated vs active;
- agent harness;
- Forge/Plan Space;
- Forge Runtime;
- local models;
- background continuity;
- Home/My Apps;
- visual/accessibility;
- provider reliability;
- migration/architecture;
- actual recent merges and blockers.

Refresh GitHub before every current-status claim.

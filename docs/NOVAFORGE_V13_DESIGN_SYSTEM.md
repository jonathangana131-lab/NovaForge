# NovaForge v13 Design System — Extreme Native Quality

NovaForge 2.0 must look and feel like an extraordinary 2026 iPhone product. This document is binding product direction, not a mood board.

## 1. Design thesis

NovaForge should feel like an absurdly capable software team inside the phone while using it feels simpler than using ChatGPT.

Influences:

- ChatGPT: conversational clarity, reasoning/activity elegance, extremely low friction;
- iOS 27 / Apple: native physics, typography, accessibility, system integration;
- Tesla: reduction, confident instrumentation, contextual controls, spatial continuity;
- Stark Future / Stark VARG: machine confidence, outdoor/readable instrumentation, purposeful motion;
- Iron Man / JARVIS: precision, responsive energy, sense of an intelligent system actively assembling something.

The output must remain original NovaForge design. Do not reproduce proprietary layouts, assets, trade dress, icons, exact gauges, or branded visual systems.

## 2. Reject these aesthetics

- generic AI purple gradients;
- giant glass cards everywhere;
- gamer RGB;
- cyberpunk neon walls;
- glowing cyan HUD rings;
- fake command-line theater;
- 3D chrome buttons;
- excessive capsules/pills;
- dashboard card soup;
- empty black space used as fake premium;
- microscopic pro controls;
- debug UUID/tool names in primary UI;
- repeated status facts;
- giant top bars;
- animations that block work;
- motion without Reduce Motion behavior.

## 3. NovaForge material hierarchy

Define a small deliberate material vocabulary.

### Ambient field
The base environment. Usually deep graphite/black or adaptive light. May have extremely subtle depth/energy state, never animated noise that wastes battery or distracts.

### Control glass
For primary native interactive controls where transparency improves spatial connection. Use iOS 27 Liquid Glass APIs with fallbacks. Keep borders/shadows restrained.

### Forge surface
The focused intelligence/mission layer. It may feel denser and more alive than normal app chrome but should remain legible and calm.

### Execution surface
Run mode and high-contrast states. The user's project gets visual priority; NovaForge chrome almost disappears.

### Opaque accessibility fallback
When Reduce Transparency is enabled, all important hierarchy must remain beautiful using adaptive opaque system surfaces, boundaries, and spacing.

## 4. Color

Primary palette should be mostly neutral.

- graphite/black/white/gray as structural colors;
- one restrained NovaForge energy accent;
- semantic green/amber/red only when actual state benefits;
- no color-only state communication.

The energy accent may feel like heat/electricity/forged metal rather than copied Iron Man blue or Tesla red. Exact palette should emerge through Simulator/device visual iteration.

## 5. Typography

Typography must communicate hierarchy before boxes do.

- large confident project/mission titles;
- compact secondary metadata;
- monospaced code only where code is actually being shown;
- high-quality numeric treatment for benchmark/performance/status values;
- avoid tiny all-caps everywhere;
- Dynamic Type is first-class.

Primary controls should remain readable one-handed and outdoors.

## 6. Motion language

Motion communicates state and spatial continuity.

Rules:

- immediate touch response;
- spring/interactive behavior where native;
- no arbitrary 800 ms cinematic delays;
- no opacity-only teleport when spatial transformation would communicate better;
- Run mode should feel connected to the project card/preview;
- Plan Space should emerge from the composer rather than open like a settings form;
- Forge Pulse should evolve from the same primary control the user just activated;
- completion should resolve, not explode;
- failure should qualify/interrupt motion without cheap screen shake.

Every custom motion path must define Reduce Motion behavior.

## 7. Haptics

Haptics indicate causal accepted state.

Examples:

- tiny selection for model/plan control choice;
- meaningful confirmation when a real build becomes runnable;
- warning when an approval/destructive action requires attention;
- completion haptic only when the mission actually reaches accepted complete state.

Do not vibrate for every token/tool event.

## 8. Signature Forge control

The primary Forge action is spatially stable and stateful.

Possible states:

- Send;
- Plan;
- Forge;
- Pause;
- Resume;
- Run.

The visual form may morph while preserving obvious accessibility labels/actions. The user should always understand what the primary action will do now.

## 9. Plan Space interaction

Plan Space is a flagship surface.

Question types can include:

- binary/segmented choices;
- slider/range;
- preview variants;
- orientation cards;
- touch-control concepts;
- model/build-depth decisions;
- free text;
- Decide for me.

One question at a time is often preferable to a giant survey. A small breadcrumb/progress cue can show that NovaForge is converging without making the user feel trapped in onboarding.

Questions should be generated only when useful. If safe defaults are obvious, NovaForge should decide and keep moving.

## 10. Reasoning / build controls

The controls must feel like premium machine modes rather than parameter forms.

### Intelligence
Fast / Balanced / Deep / Extreme.

A slider or discrete detents may be tested. The control should show concise consequences such as `faster`, `more planning`, `more review`, not pretend to expose hidden thought tokens.

### Build Depth
Prototype / Polished / Obsessive / Go Crazy.

This is visually distinct from Intelligence. Intelligence changes depth of individual decisions; Build Depth changes how far the harness takes the product through testing/polish.

### Creativity
Faithful / Inventive.

### Refactor risk
Preserve / Rebuild.

### Autonomy
Ask / Assist / Build / Autopilot.

Advanced details can expand; default view remains simple.

## 11. Forge Pulse

Primary mission status should be compact and alive.

Example collapsed state:

`FORGING OPENROAD`
`Touch controls · 3 checks running`

Progress stages should represent actual durable mission state, not fake percentage theater.

Tap/expand:

- stage graph;
- meaningful actions;
- exact evidence on demand;
- decisions/approvals;
- current model/environment.

The primary display should not spam every filesystem read or tool JSON call.

## 12. Forge-line energy language

Create an original restrained signature motion motif:

- thin light/energy trace or edge movement;
- tied to real work states;
- intensifies subtly during execution;
- settles on completion;
- interruption/failure changes its behavior;
- no neon halo;
- no constant GPU-heavy decoration;
- disabled/simplified under Reduce Motion/thermal/performance constraints.

## 13. Home / My Apps redesign

Home should answer one thing immediately: **what do you want to make or run?**

Potential hierarchy:

- concise create prompt / Forge entry;
- recent runnable creations with real thumbnails;
- active mission if one exists;
- model/local status only when materially relevant;
- no repository dashboard by default.

Project cards:

- icon;
- title;
- latest real preview;
- last changed;
- runnable/offline state;
- active build indicator if applicable.

Tap project should favor Run/open. Editing is easy but not mandatory before experiencing the project.

## 14. Forge screen redesign

Forge should center:

- current project context;
- conversation/intent;
- Plan Space when needed;
- Forge Pulse while building;
- concise generated result;
- primary action;
- optional model/intelligence controls.

Avoid a permanent toolbar jungle. Advanced controls appear contextually or in one intentional sheet.

## 15. Model Center redesign

Model Center should feel like choosing an engine, not configuring API internals.

Each model may show:

- model name/family;
- Local / Cloud;
- installed/download size;
- device compatibility;
- measured tokens/sec when available;
- reasoning/tool/vision capabilities;
- privacy status;
- recommended uses;
- support status.

Normal users see friendly summaries. Experts expand architecture/quantization/context/template details.

Download states must be beautiful and exact: bytes/progress/resume/validating/ready.

## 16. Run mode

Run mode gives the user's creation visual ownership.

- near-zero NovaForge chrome;
- orientation follows project policy;
- reliable accessible escape/back control/gesture;
- no debug badge unless requested;
- safe runtime error handling;
- optional inspector gesture in edit mode;
- project can feel like a real tiny app/game.

Transitions into/out of Run should preserve spatial continuity where practical.

## 17. Direct-edit selection

Visual Picker selection should be unmistakable but elegant.

- subtle outline/anchor around selected element;
- no permanent debug boxes;
- contextual `Edit with NovaForge` affordance;
- source identity hidden until expert view;
- selection remains accessible through semantic navigation where feasible.

## 18. Game control designer

Touch controls should be editable directly on the running game:

- drag joystick/buttons;
- resize if allowed;
- opacity/auto-hide options;
- one-handed/two-handed presets;
- safe-area-aware;
- controller mapping.

`Keep layout` becomes durable project configuration.

## 19. Physics Playground

When a generated game exposes tuneable physical parameters, provide a polished temporary live panel rather than text fields in a debug sheet.

Controls can be grouped by meaningful concepts: Handling, Power, Camera, Suspension, Grip. Exact raw values expand for experts.

## 20. Visual time machine

History should be tactile and visual.

Imagine scrubbing through accepted checkpoints and seeing the actual project preview evolve. Major milestones can have short labels. Releasing at a point gives Compare / Restore / Try another idea.

Do not require Git vocabulary.

## 21. Completion

Completion should feel confident and calm:

- Forge Pulse resolves;
- runnable project expands;
- subtle haptic;
- `Ready` or equivalent;
- user immediately experiences the creation.

No confetti by default.

Proof is available on demand: tests, screenshots, runtime status, known limitations.

## 22. Errors

Error UI must be actionable and non-theatrical.

Examples:

- `Local model ran out of memory — project is safe. Switch to smaller model / Cloud / Retry after unloading.`
- `Runtime error in game.js:214 — Repair & Relaunch.`
- `OpenAI key rejected — Update key.`

Do not surface internal enum/module error strings as primary UI.

## 23. Background / Live Activity

Live Activity should look like a premium system extension, not a dashboard.

Show:

- project/mission name;
- meaningful current stage;
- progress only when based on real bounded work;
- needs-attention/completion states.

Possible controls where platform permits: Pause/Open. Do not expose unsafe destructive controls casually.

## 24. Notifications

Notify only for:

- user decision needed;
- requested milestone;
- blocked mission;
- mission complete;
- model download complete if requested.

No token/tool spam.

## 25. Accessibility

Every flagship interaction must work without visual/motion assumptions.

- Plan Space controls expose clear labels/value/consequence;
- Forge Pulse announces meaningful stage changes, not every animation frame;
- model benchmark values have semantic descriptions;
- project cards have useful VoiceOver summaries;
- visual selection has non-visual navigation path where feasible;
- Dynamic Type does not collapse Forge into unreadable chips;
- Reduce Motion removes nonessential spatial effects while preserving state clarity;
- Reduce Transparency uses opaque adaptive surfaces;
- Increase Contrast remains intentional;
- no color-only state.

## 26. Perceived latency

Every tap should acknowledge instantly.

If model work will take seconds:

- composer transitions immediately;
- mission is durably created;
- truthful waiting/starting state appears;
- user can leave/pause where safe.

Never leave a button looking dead while a network call starts.

## 27. Long content / streaming

Streaming text and agent activity must not cause global re-layout/jank. Keep high-frequency updates localized. Virtualize/archive long histories. Maintain scroll position and intentional auto-follow behavior.

## 28. Screenshot-driven visual acceptance

Every major rewritten screen should follow:

`IMPLEMENT -> SIMULATOR -> INTERACT -> SCREENSHOT -> CRITIQUE -> REDESIGN -> IMPLEMENT -> SCREENSHOT -> COMPARE -> PROFILE -> ACCESSIBILITY -> FIX -> REPEAT`.

A source-only review is insufficient for major visual acceptance.

## 29. Design acceptance questions

Before calling a screen finished ask:

- Does the first glance make its purpose obvious?
- Is anything repeated?
- Are there controls visible that could be contextual?
- Does it feel native at 60/120 Hz?
- Is there any debug/legacy visual residue?
- Does it look great in both adaptive light/dark where supported?
- Does Larger Text remain coherent?
- Does Reduce Motion/Transparency remain premium?
- Can a one-handed user hit the primary actions?
- Is the user seeing evidence or theater?
- Would this feel embarrassing next to ChatGPT or a first-party Apple app? If yes, keep working.

## 30. Originality requirement

The goal is not `make ChatGPT + Tesla + Stark + Iron Man screens`.

The goal is for NovaForge to develop a recognizable design language of its own: calm, dark, precise, fluid, intelligent, physically coherent, and extraordinarily polished.

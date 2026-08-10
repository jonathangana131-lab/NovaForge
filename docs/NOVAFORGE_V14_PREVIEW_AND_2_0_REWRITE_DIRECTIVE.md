# NovaForge V14 — Pre-2.0 Preview + Full 2.0 Rewrite Directive

**User decision:** 2026-08-10  
**Protocol:** NF-SWARM-v14  
**Repository:** `jonathangana131-lab/NovaForge`  
**Live baseline when written:** `main@f7560acbc50c624af46858a3aefc195fae5bc48f`

Live GitHub always outranks the snapshot SHA above. This document records the user's current product priority and must be reconciled with current code, PR ownership, tests, and evidence before implementation.

---

## 1. Product decision

NovaForge should ship a **fully working, polished pre-2.0 Preview** before waiting for the entire NovaForge 2.0 vision to close.

The Preview should focus on what the user can actually try now:

- the normal NovaForge chat/agent harness;
- working truthful AI providers;
- strong first-class Local AI;
- the mature RAM/context work from Forge Compact;
- a polished real effort control including **Ultra**;
- all current NovaForge themes;
- whatever near-done V14 features can be integrated and fully closed without destabilizing the Preview.

The Preview is **not** permission to abandon NovaForge 2.0. It is a deliberate intermediate product closure target so the user can use NovaForge again while the deeper 2.0 reinvention continues.

The full NovaForge 2.0 release remains the long-term north star and should treat the legacy user-facing architecture as replaceable: navigation, menus, chat layout, composer, project surfaces, settings/control surfaces, run/history surfaces, game/runtime tooling, Physics Playground, and related interaction structures should be reconsidered and rewritten where the old concept no longer fits the creation-OS direction.

---

# PART A — NOVAFORGE PREVIEW (PRE-2.0)

## 2. Preview product promise

> Open NovaForge, choose a truthful AI route, chat with the agent, let it use its normal tools, choose how much effort it spends, use Local AI without silent cloud fallback, keep memory under control, switch among all NovaForge themes, leave/relaunch, and continue without the app feeling like a half-built 2.0 construction site.

This Preview is intentionally smaller than the final 2.0 product. It should be excellent at the normal agent experience first.

## 3. Preview closure scope

### 3.1 Normal agent harness must be genuinely usable

Close and polish the existing chat/agent loop rather than replacing the whole shell in this lane:

- reliable new chat, existing-chat load, chat switching, deletion and relaunch persistence;
- prompt send, streamed assistant response, stop/cancel, provider error recovery and retry where supported;
- canonical tool/activity presentation, approvals and artifacts remain usable;
- no permanent `planning next move` / running-state deadlocks;
- model/provider changes repair stale selections safely;
- the normal user should not need GitHub, Xcode, or terminal surfaces for ordinary use;
- repeated tool calls and long chats should not degrade into obvious UI lag or runaway memory/context growth.

### 3.2 Working AI routes — truth before breadth

Provider reliability is a Preview blocker.

Resolve or safely supersede the useful work in PR #12 without inheriting its known support/privacy/dialect/replay/fresh-authority blockers.

Preview provider rules:

- fresh selectable hosted models must have a current supported route, auth contract, dialect and tool/reasoning behavior;
- private/legacy ChatGPT/Codex compatibility may remain only where required to recover an already accepted legacy run; it must not mint a fresh unsupported route;
- do not silently migrate a saved hosted recipient to another hosted provider when recipient/privacy/data-use semantics materially change;
- stale, deprecated, wrong-dialect or known-broken models must not appear as normal supported fresh choices;
- provider failure copy must be actionable and sanitized;
- Local Only must never silently route to cloud;
- prefer a smaller known-good model list over a large unreliable picker.

### 3.3 Local AI is a real Preview feature

Local AI must work as a normal first-class route, not only as a settings demo.

Required:

- Local Model Center truthfully shows installed/downloading/paused/invalid/unavailable state;
- model download, pause/resume, checksum/validation, delete/reinstall and recovery work;
- one clearly recommended local default may be shown only when exact runtime/device evidence supports the claim;
- a selected local model can complete the normal chat/agent workflow appropriate to its qualified capability;
- Local Only has a deterministic zero-hosted-fallback/network-audit path;
- static catalog strings cannot self-award physical-device qualification;
- no fake or estimated tok/s is presented as measured throughput.

Use the strongest accepted V14 Local Model Qualification / Local Model Fabric work when it is mature enough to integrate. Do not block Preview on experimental beyond-RAM research.

### 3.4 Forge Compact / RAM work must reach the real runtime

The Preview should benefit from mature RAM/context work already being built rather than leaving it package-only.

Prioritize measurable integration:

- Project Capsule / compact authoritative mission context where it can safely replace raw transcript replay;
- Project Brain retrieval only where its authority is strong enough for the normal agent loop;
- memory-pressure-aware runtime governor behavior;
- reduce context/KV budget before iOS termination;
- unload or de-escalate expensive local tiers gracefully under memory/thermal pressure;
- exact prefix/KV reuse only when model/tokenizer/template/tool identity matches;
- llama.cpp mmap or quantized KV only when the exact runtime supports the selected profile and correctness is proven.

Experimental flash-backed neuron loading, TurboQuant, sparse expert paging, BitNet and beyond-RAM modes remain research until exact iPhone evidence promotes them.

**Preview RAM goal:** repeated normal agent turns on the iPhone 12/A14 baseline without obvious uncontrolled memory/context growth or an avoidable memory-pressure crash. Record exact device/runtime evidence; never invent a RAM-saving percentage.

### 3.5 Finish the reasoning / effort control as a real feature

Current `main` already contains a polished five-stop `ComposerReasoningControl` in `AgentPad/Views/ChatComposer.swift`, backed by `AgentRunPreferenceStore` and accessibility-adjustable behavior.

Preview user-facing target:

**Low -> Medium -> High -> Extra High -> Ultra**

Rules:

- **Ultra must map to the strongest actually implemented reasoning/orchestration behavior.** It cannot be a cosmetic label;
- an internal implementation mode such as `ultraCode` may remain if useful, but the normal user-facing top level should be `Ultra` rather than developer-ish `UltraCode` unless later product testing demonstrates a better name;
- provider/model capability bounds must remain truthful;
- if a route cannot honor a requested level, adapt, disable or explain instead of silently pretending;
- preserve the current slider quality, haptics, Reduce Motion handling and accessibility adjustable action;
- regression-test selection persistence, provider/model switching and relaunch;
- do not create a second competing effort authority. Reconcile this with V14 Build Depth / Intelligence as Composer/Plan Space integration lands.

### 3.6 Keep and polish all current NovaForge themes

Preview retains all current theme worlds defined in `AgentTheme.swift`:

1. Matrix Rain
2. Midnight Black
3. White Gold
4. Arctic Glass
5. Ember Core

Acceptance:

- selected theme persists through relaunch;
- Forge/chat/composer, drawers, settings/control, Local Model Center, approvals, artifacts and empty/loading/error/offline states remain readable;
- no theme-specific clipping, bad contrast, broken glass fallback or unusable control state;
- capture and critique a release-candidate screenshot tour for all five themes.

### 3.7 Near-done V14 features may enter Preview only if they close cleanly

Likely candidates include:

- canonical Composer intent controls from PR #125;
- Plan Space app wiring from the strongest accepted descendant of #143/#163;
- Local Model Center truth/qualification work;
- other nearly-finished user-visible features that do not require dragging the entire Full Forge/Runtime graph into the Preview.

**Rule:** “almost done” is not enough. Any feature admitted to Preview must pass app wiring, Simulator/runtime interaction, screenshot critique, accessibility and performance gates appropriate to the feature. Otherwise leave it for full 2.0.

## 4. Preview non-goals

Do **not** make these full-2.0 capabilities blockers for the Preview:

- complete Full Forge autonomous mission graph;
- autonomous game self-play and every playtest persona;
- final 2D/3D Forge Kits;
- final Physics Playground / Game Inspector;
- final visual direct editing / visual picker;
- final Home/My Apps reinvention;
- final History/Time Machine reinvention;
- final generated-app Completion Constitution UX;
- experimental beyond-RAM inference;
- wholesale navigation/menu/chat-layout rewrite.

## 5. Preview UI rule

**Polish the current shell; do not canonize it.**

The historical Forge / Workspace / History / Control composition and the old chat/menu architecture may survive this Preview if they are stable and polished enough. They are explicitly **not** a permanent NovaForge 2.0 information architecture.

Small cleanup is encouraged. A wholesale shell rewrite belongs to Part B below.

## 6. Preview closure order

Unless live blockers force another sequence, converge in this order:

1. provider/runtime truth and normal send/stream/tool loop;
2. Local AI install/run/local-only truth;
3. Forge Compact runtime integration + memory-pressure behavior;
4. effort control -> real **Ultra** behavior;
5. session persistence/relaunch + long-session performance;
6. five-theme visual sweep;
7. accessibility + Dynamic Type + Reduce Motion/Transparency;
8. iPhone 12/iOS 27 Simulator full tour;
9. physical iPhone 12 Local AI smoke/thermal/memory evidence where required;
10. adversarial retry/offline/model-missing/provider-failure tests;
11. exact final-head release proof.

Use one integration closer for high-contention app/runtime paths where practical. Other workers should attack independent provider, Local AI, RAM, theme, accessibility, performance and QA lanes instead of waiting.

## 7. Preview Acceptance Constitution

Do not call Preview ready until exact-head evidence supports all required items:

- [ ] App builds on the required Xcode/iOS 27 toolchain.
- [ ] Clean-install launch succeeds.
- [ ] Relaunch with existing user data succeeds without destructive reset.
- [ ] New chat -> send -> streamed reply -> idle completes.
- [ ] Tool-bearing run completes with truthful activity/approval/artifact UI.
- [ ] Stop/cancel and provider failure recover composer state.
- [ ] A fresh supported cloud route completes a normal run using its current correct provider contract.
- [ ] Local model download/resume/validation works.
- [ ] A qualified Local route completes a normal run.
- [ ] Local Only produces zero hosted fallback/network dispatch.
- [ ] Repeated-turn memory/context test does not show uncontrolled growth; memory pressure degrades gracefully.
- [ ] Effort UI exposes Low / Medium / High / Extra High / Ultra and each maps to real bounded behavior.
- [ ] All five themes persist and pass screenshot/readability review.
- [ ] Chat list/drawer, composer, model picker, settings/control and core menus have no major clipping, misalignment or jitter defects.
- [ ] VoiceOver-critical paths, Dynamic Type, Reduce Motion and required accessibility checks pass.
- [ ] No known P0/P1 defect remains.
- [ ] Final installable candidate is bound to exact source SHA and exact acceptance receipts.

**Definition of Preview complete:** engineering/truth done **and** product/experience done. Package tests alone do not make the Preview usable.

---

# PART B — FULL NOVAFORGE 2.0 REWRITE

## 8. The Preview is not the final UI architecture

After the Preview is stable, NovaForge 2.0 should continue toward the creation-OS north star with an explicit willingness to replace the older AI-era product shell rather than perpetually patch it.

The user's direction is that the old concept should **not** constrain NovaForge 2.0 simply because it already exists. The original navigation/menu/chat structure came from an older product concept and should be reevaluated from first principles.

This does **not** mean throwing away proven security/provider/local-model/domain behavior. Preserve accepted truth and user data behind new boundaries. Rewrite presentation, composition and obsolete state architecture aggressively when that creates a better product.

## 9. 2.0 systems to redesign/rewrite as one coherent product

Every major user-facing system is review-for-rewrite rather than assumed sacred:

### 9.1 App shell / information architecture

- replace the historical four-tab architecture if a better creation-OS structure tests better;
- rewrite `AppRoot` composition into smaller, durable feature boundaries;
- make projects/context feel native rather than bolted onto chat;
- remove duplicated routes and legacy aliases from normal UI while retaining compatibility where required.

### 9.2 Forge / chat experience

- rewrite chat layout, chat list/drawer, conversation actions and project switching;
- rewrite the Composer as the flagship creation instrument, not a decorated text field;
- integrate Plan Space as a temporary decision surface rather than a permanent card stack;
- redesign tool calls, approvals, progress and mission steering around the user's actual next action;
- keep one obvious morphing primary action instead of accumulating buttons.

### 9.3 Menus, sheets and controls

- inventory every old menu/sheet/popover;
- delete obsolete menus instead of restyling them;
- merge duplicated settings/actions;
- replace debug/developer-first menus with context-aware product controls;
- make common controls one-handed, direct and native to iPhone.

### 9.4 Home / projects / Workspace

- rewrite Home/My Apps as the calm normal-user entry point when the product requires it;
- simplify Workspace around files/artifacts relevant to the active creation rather than desktop-IDE imitation;
- make Git/GitHub/Xcode optional Pro depth, never the normal navigation spine.

### 9.5 Local Model Center

- rebuild the user-facing Local Model Center around exact-device truth, simple recommended choices, Local Only privacy, download/readiness state and measured evidence;
- hide research complexity until the user asks for it;
- integrate Local Model Fabric, qualification, Forge Compact and resource policy as one coherent experience rather than separate settings pages.

### 9.6 Full Forge mission experience

- replace transcript-centric long-running-agent UX with durable mission state;
- visualize plan/stage/progress/evidence without becoming a CI dashboard;
- support steering, interruption, accepted checkpoints, retry/repair and model hot-swap;
- Complete must be evidence-backed, never model-declared.

### 9.7 Run / Experience / History

- redesign Run mode as a first-class full-screen experience;
- redesign History/Time Machine around meaningful visual/project checkpoints, restore/fork/compare and accepted evidence;
- do not expose raw internal logs as the primary product surface.

### 9.8 Visual editing / generated runtime / game tooling

- rewrite visual editing around direct manipulation and stable source/runtime element identity;
- rebuild 2D/3D generated-runtime tooling around safe semantic controls and deterministic evidence;
- rethink Physics Playground, Game Inspector and generated-project physics/control tooling as coherent creation instruments rather than inherited debug panels;
- support autonomous self-play/playtest only through authorized runtime capabilities and exact evidence.

### 9.9 Settings / Control

- remove settings-form sprawl;
- keep only controls that materially affect creation, privacy, intelligence, autonomy, resources or provider/account state;
- move expert/pro settings deeper;
- do not duplicate controls already represented contextually in Composer/Plan Space.

### 9.10 Design system / motion / interaction

- replace leftover generic AI visual language and old chrome;
- use iOS 27/Liquid Glass purposefully with strong fallbacks;
- develop an original NovaForge identity instead of copying ChatGPT or any previous concept;
- eliminate card soup, giant chrome, chip trains, neon theater and debug-console aesthetics;
- treat motion, haptics, frame pacing, keyboard behavior, safe areas, landscape states and accessibility as system-level design, not cleanup.

## 10. 2.0 rewrite rules

1. **Do not reproduce the old UI with new colors.** If information architecture is wrong, fix the information architecture.
2. **Do not rewrite accepted truth merely for rewrite purity.** Provider/security/local-model qualification/evidence contracts may survive behind new APIs when they are still correct.
3. **Preserve user data through explicit migration.** Projects, chats, settings, model downloads/checkpoints and accepted evidence must not be casually destroyed.
4. **Shrink giant presentation/state files.** New feature boundaries should make ownership/testing/runtime behavior clearer.
5. **Delete superseded UI.** Temporary adapters need owners and removal conditions.
6. **Visual quality is a release gate.** Real Simulator/runtime screenshots, interaction critique, accessibility and performance are required.
7. **Physics/runtime behavior must be tested, not merely rewritten.** Generated-project controls/physics/self-play need deterministic journeys and regression evidence.
8. **Do not make 2.0 a generic chatbot, GitHub dashboard or mobile desktop IDE.** It remains an iPhone-native AI creation OS.

## 11. Full 2.0 acceptance direction

The final 2.0 experience should feel like one coherent system:

**Describe -> Understand -> Forge -> Run -> Experience -> Critique -> Repair -> Polish -> Complete**

A user should not need to understand NovaForge's package graph, GitHub swarm, CI, internal evidence domains or model-runtime research to create something. That complexity belongs underneath a calm, original, highly interactive iPhone product.

---

# PART C — GO WORKER PRIORITY

## 12. Immediate worker behavior after this directive

Until the pre-2.0 Preview Acceptance Constitution is closed, `GO` workers should treat **Preview closure as the immediate product flagship** unless a live non-conflicting 2.0 foundation lane is clearly higher value and does not delay or destabilize Preview.

A worker should:

1. fresh-check current `main`, open/recent PRs, issue #23, Actions and active ownership;
2. inspect this directive;
3. choose the highest-value unowned Preview closure rung;
4. implement real product work, not just package abstractions;
5. build/run/interact/screenshot/test as appropriate;
6. persist findings, evidence, blockers and code to GitHub;
7. refresh and continue.

Do not wait behind one high-contention path. Independent lanes include provider reliability, Local AI runtime, qualification, Forge Compact integration, long-session memory/performance, effort/Ultra semantics, theme QA, accessibility, simulator acceptance and release-proof hardening.

Once Preview is genuinely accepted, shift product gravity back toward the full 2.0 rewrite and feature-closure roadmap above.

---

## 13. Truth boundaries

Never fabricate:

- working provider/model support;
- Local Only behavior;
- physical-device qualification;
- RAM savings;
- tok/s;
- thermal/energy results;
- build/test/runtime success;
- visual acceptance;
- autonomous playtest success;
- background execution guarantees.

Research results are not iPhone 12 results. Simulator results are not physical-device results. A label such as `Ultra`, `Complete`, `Qualified`, or `Ready` must point to real behavior/evidence.
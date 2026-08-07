# NOVAFORGE CURRENT STATE
Snapshot: 2026-08-06
Repository: jonathangana131-lab/NovaForge
Main SHA inspected: 4f7b1bd0523571a29f725c085a2334c17a1b1ceb

This file distinguishes LIVE FACT, INFERENCE, and UNVERIFIED. GitHub main always wins over this snapshot.

## 1. Executive state

### LIVE FACT
NovaForge is a substantial SwiftUI + SwiftData iOS codebase with:
- a four-surface product model: Forge, Workspace, History, Control;
- local llama.cpp integration through vendored swift-llama-cpp;
- hosted provider plumbing;
- project/workspace concepts;
- terminal/workspace tooling;
- approvals/policy infrastructure;
- durable run/persistence/recovery infrastructure;
- widgets/run activity;
- extensive unit/UI tests and simulator scripts;
- a separate AgentHarnessKit package that contains strong agent-domain/provider/policy/store abstractions.

### LIVE FACT — primary broken area
The phone AI/provider path is not trustworthy enough for release.
Main still exposes a `ChatGPT` provider backed by a private `https://chatgpt.com/backend-api/codex/...` route as part of `agentRuntimeProviders`.
The user reports repeated provider/module errors.

PR #12, “Fix phone provider model failures”, is an open draft targeting this problem.
PR #12 head at snapshot: 03c5a7e7a09419f9f5b25d735556eb407560b1b2.
At this snapshot its PR-triggered CI failed in Critical verification; downstream visual/release jobs were skipped.
Therefore PR #12 is NOT merge-accepted.

### LIVE FACT — repository contamination
Open branches/PRs include substantial unrelated Voltline scooter/game work.
Examples at snapshot include PRs #8, #9, #10, #15, #16, #20, #21.
PR #8 explicitly states the Voltline work should not merge into NovaForge main.
Treat these as foreign/quarantined until moved/closed; do not use them as NovaForge roadmap authority.

## 2. Product surface

README/AGENTS describe:
- Forge: agent chat/live mission strip/approvals;
- Workspace: files/artifacts/terminal;
- History: durable run receipts;
- Control: settings/providers/models/security;
- projects as context rather than a primary tab.

Internal project/scheme remains AgentPad.xcodeproj / AgentPad.
User-facing product is NovaForge.

## 3. Architecture map

### App / composition
`AgentPad/App/AgentPadApp.swift`
- application entry/composition;
- currently large and should be audited for lifecycle/state responsibilities.

### Models / project domain
Notable large files include:
- `AgentPad/Models/Models.swift`
- `AgentPad/Models/ProjectOSEngine.swift`
- `AgentPad/Models/ProjectSummary.swift`
- launch/persistence repair logic.

### Services / runtime
Key areas:
- `AIProvider.swift`: app-facing provider enum, endpoint/model lists, provider catalog store;
- `AgentRuntime.swift`: large legacy/app runtime responsibilities;
- `AgentSystemProductionComposition.swift`: production composition into package engine;
- `AgentHostedProviderTransport.swift`;
- `AgentLocalModelProviderTransport.swift`;
- `AgentProductionProviderGateway.swift`;
- `AgentCanonicalContextPreparer.swift`;
- `LocalModelRuntime.swift`;
- `OpenAIClient.swift`;
- `KeychainStore.swift`.

### Infrastructure
Key areas:
- `SwiftDataAgentStore.swift`;
- persistence models/projectors;
- durability/recovery;
- approval signing/policy store paths;
- POSIX workspace effect backend;
- checkpoint store.

### Tools
- command runner;
- diff engine;
- sandbox tool executor;
- sandbox workspace;
- artifacts.

### Views
Large product surfaces include:
- `AppRootView.swift`;
- `ChatView.swift`;
- `FilesView.swift`;
- `RunsView.swift`;
- `SettingsView.swift`;
- `ArtifactPreviewSheet.swift`;
- project dashboard files;
- Forge chrome;
- terminal.

### Design
- `AgentTheme.swift`;
- `GlassDesign.swift`;
- `NovaFacelift.swift`;
- `CodeHighlighter.swift`.

### Package foundation: AgentHarnessKit
Strong existing modular domains include:
- AgentDomain;
- AgentEngine;
- AgentPolicy;
- AgentProviders;
- AgentReducerCore;
- AgentShadow;
- AgentStore;
- AgentTools;
- AgentTransport.

This package contains deterministic provider capability negotiation, trusted route provenance, approval/policy concepts, event/run machinery, tool registry, and tests. Preserve/elevate it.

## 4. Architecture risk map

### Risk A — competing app/package abstractions
The app layer has provider/runtime abstractions while AgentHarnessKit also has provider/runtime domain contracts.
Goal: package owns canonical contracts; app owns iOS composition/adapters/UI state.
Do not create a third provider system.

### Risk B — monolithic files
Repository tree shows several very large Swift files (roughly 100–300KB scale), including runtime, root UI, persistence store and tests.
Size alone is not a bug, but these files are high-risk for:
- observation invalidation;
- compile/review cost;
- accidental coupling;
- giant switches;
- weak ownership;
- hard-to-isolate tests.

Refactor only with measured boundary value.

### Risk C — provider UI != wire truth
Main `AIProvider` currently has:
- `.local`
- `.openAI`
- `.openAICodex`
- `.openRouter`
- `.openCodeZen`
- `.custom`

`agentRuntimeProviders` currently includes Zen, Local, ChatGPT/private Codex, and OpenAI.

Main maps OpenCode Zen to one provider-wide chat-completions URL.
Current OpenCode Zen documentation uses different dialects by model family, including Responses endpoints for GPT-family models and chat-completions for various OpenAI-compatible models.
This means provider+model+dialect must become one route contract.

### Risk D — hard-coded model catalogs can stale
Static model arrays are useful fail-closed offline fallback but cannot be product truth forever.
A live catalog must be validated/capability-filtered and must never turn an unknown model into a presumed supported route.

### Risk E — stale branches/PRs
There are many provider experimentation branches and Voltline branches.
Workers must not infer “newest branch = intended architecture.”
Only main + accepted current docs + explicit active control issue/lane claims are authoritative.

## 5. Provider matrix at snapshot

| Provider | Product status | Auth | Known route shape | Agent runtime | Snapshot verdict |
|---|---|---|---|---|---|
| Local llama.cpp | SUPPORTED-IN-PROGRESS | none after model download | on-device | canonical local lanes exist | Functionality real; physical iPhone performance/support matrix still needs exact acceptance |
| OpenAI public API | SUPPORTED-IN-PROGRESS | API key in Keychain | public OpenAI API | canonical hosted route exists | Keep; contract-test exact models/dialects |
| ChatGPT / openAICodex private backend | LEGACY / REMOVE-FROM-FRESH-SELECTION | OAuth-ish ChatGPT credential | private chatgpt.com backend-api/codex | canonical route exists in code | Do not present as dependable public provider |
| OpenCode Zen | SUPPORTED-IN-PROGRESS | API key for paid; some `-free` models intentionally anonymous in code | model-dependent | canonical hosted Zen route exists | High-value route, but endpoint/dialect must be model-aware |
| OpenRouter | LEGACY/UNVERIFIED for full agent | API key | chat completions | not listed as canonical app runtime provider | Retain saved config if safe; do not imply full agent compatibility |
| Custom OpenAI-compatible | LEGACY/UNVERIFIED for full agent | endpoint-specific API key | configured chat completions | not listed as canonical app runtime provider | Same as OpenRouter until tool/capability contract is proven |

## 6. PR #12 audit

Title: Fix phone provider model failures
State at snapshot:
- open;
- draft;
- mergeable at metadata level;
- head `03c5a7e7a09419f9f5b25d735556eb407560b1b2`;
- CI: failed Critical verification;
- visual proof skipped;
- release verification skipped.

Changed files at snapshot:
- `.github/workflows/ci.yml`
- `AgentPad/Models/AppLaunchPersistence.swift`
- `AgentPad/Services/LocalModelRuntime.swift`
- `AgentPad/Views/ChatComposer.swift`
- `AgentPad/Views/SettingsView.swift`
- provider/canary/security/contract tests
- CI scripts.

Useful direction in PR #12:
- fresh phone selection becomes Zen, Local, public OpenAI;
- saved private ChatGPT selection migrates to Zen;
- unknown/corrupt provider selection falls back local rather than authorizing a network route;
- errors become LocalizedError/actionable;
- interrupted local download keeps resumable bytes;
- adds security/contract tests;
- updates CI runner target.

Open questions / required before merge:
1. Determine exact Critical verification failure from logs/artifacts.
2. Re-run on exact head after fix.
3. Verify provider picker and launch migration against real saved-state permutations.
4. Verify Zen model-dialect routing; PR #12 does not by itself establish that every exposed Zen model uses the right API dialect.
5. Verify public OpenAI models currently exposed are actually available to the user's API account before recommending.
6. Verify cancellation/partial stream/run-state integrity on network loss.
7. Perform physical iPhone acceptance for local model lifecycle/performance.
8. Re-run visual census because downstream visual job was skipped.

## 7. Other NovaForge PRs

### PR #2 — Fix Zen folder runs and streaming handoff
Open draft; mergeable false at snapshot.
Reported scope includes preserving provider reasoning metadata for some Zen/DeepSeek tool continuation and fixing live-stream->persisted-message handoff.
Its base SHA predates current main, so it must be rebased/re-audited rather than merged blindly.
Potentially valuable behavior should be mined into a fresh lane after P0 provider contract is settled.

### PR #3 — Define release plan and harden proof gates
Open; mergeable false at snapshot.
Contains useful release-proof thinking and canonical four-surface vocabulary, but also predates current main and cannot be treated as source of truth.
Mine intent, not stale code.

## 8. CI state

Main `.github/workflows/ci.yml` at snapshot uses:
- Critical verification on `macos-26`;
- synchronized visual proof after verify on pushes/explicit dispatch;
- exhaustive release verification on schedule/explicit dispatch;
- `ci/verify.sh` as critical test entry;
- artifact upload for diagnostics.

PR #12 changes runner targeting to `xcode-27`, but that branch's current Critical verification is failing.

CI policy going forward:
- never “fix” CI by weakening required tests;
- record exact candidate SHA;
- preserve diagnostics artifacts;
- maintain deterministic provider fixtures independent of live network;
- use physical-device acceptance outside cloud simulator for device-only claims.

## 9. Visual evidence

A `ci-shots` branch exists with real simulator screenshot artifacts, including chat, keyboard/composer, agent typing, drawer, local model settings, model picker, artifact preview, project route, mission dossier, and accessibility frames.

This architecture session confirmed that evidence exists but could not execute Xcode/Simulator or render the binary screenshots in the current tool environment.
Therefore:
- no fresh visual-quality claim is made here;
- the first visual worker must inspect the latest exact-head screenshot census and run the simulator loop;
- screenshots are evidence only for the commit that generated them.

## 10. What is clearly real vs needs proof

Clearly real from source structure:
- provider abstraction and capability types;
- package policy/approval system;
- run engine/store concepts;
- SwiftData persistence/recovery work;
- sandbox workspace/tool infrastructure;
- local llama.cpp integration code/vendor;
- UI surfaces and CI/simulator tooling;
- extensive tests.

Needs exact runtime proof:
- every provider/model currently selectable can successfully complete intended journeys;
- local inference speed/memory/thermal behavior on iPhone 12;
- current physical-device file/terminal workflows;
- all UI screenshot paths match current main;
- current error/recovery behavior under real network failures;
- long-run stability under many tool calls;
- accessibility/performance budgets.

## 11. Immediate source-of-truth rule

When this file conflicts with:
1. live GitHub main;
2. an accepted product constitution/provider contract;
3. exact-head CI/device evidence;

the newer direct evidence wins. Update this file in the same PR when a major architectural truth changes.

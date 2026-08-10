# V14 Preview — Forge Compact Integration Audit

Worker: `GPT56-SOL-NF-V14-CAPSULE-RENDER-0810`  
Protocol: `NF-SWARM-v14`  
Audit base: `main@9499a5c3bd3d5bd9e6d5a7c0cd11f08575bf1a8b`  
Date: 2026-08-10

## Verdict

**ForgeCompactCore is currently package truth, not IN APP / INTEGRATED Preview runtime behavior.**

Do not credit the current iPhone app with Forge Compact RAM/context reduction, Project Capsule prompt replacement, governor-driven context selection, or runtime memory-pressure adaptation solely because `Packages/ForgeCompactCore/**` exists and passes its package tests.

## Evidence

### Xcode app dependency graph

`AgentPad.xcodeproj/project.pbxproj` currently declares only these local Swift package references:

- `Vendor/swift-llama-cpp`
- `Packages/AgentHarnessKit`

There is no `Packages/ForgeCompactCore` local package reference and no `ForgeCompactCore` product dependency in the app project at this audit base.

### AgentHarnessKit dependency graph

`Packages/AgentHarnessKit/Package.swift` declares its internal AgentDomain/AgentEngine/AgentTools/AgentProviders/AgentStore/AgentShadow/AgentPolicy/AgentTransport targets. It declares no dependency on `ForgeCompactCore` and no target consumes that product.

### Live provider-context preparation

`AgentPad/Services/AgentCanonicalContextPreparer.swift` imports AgentDomain, AgentEngine, AgentProviders, AgentTools, CryptoKit, and Foundation. It does not import ForgeCompactCore.

The current provider-turn preparation path constructs messages from:

- configured system/developer instructions;
- `state.artifacts` / `state.checkpoints` supplement;
- `state.modelItems`, including explicit reasoning/tool-call replay handling;
- canonical tool definitions and request metadata.

It then performs request-byte/token-window guards and returns the prepared provider turn. No `ProjectCapsule`, `ProjectCapsuleBuilder`, `ForgeCompactGovernor`, or Forge Compact accounting receipt participates in this path at the audited head.

## Why this matters for the Preview

The accepted Preview directive prioritizes a usable normal agent with strong Local AI and mature Forge Compact/RAM behavior. The current repository has a substantial ForgeCompactCore truth package, but the normal app/provider path still prepares context independently. Therefore the Preview should classify Forge Compact as **IN WORK / PACKAGE-READY**, not **IN APP / INTEGRATED**, until a canonical adapter is actually wired and exercised.

## Safe next integration rung

Do **not** simply replace `state.modelItems` with a flattened capsule. The canonical transcript currently enforces tool-call adjacency, reasoning replay, provider-call identity, and other agent-harness invariants. Blind replacement could break tool execution or lose required conversational causality.

A safe integration slice should:

1. define exactly which accepted project/mission facts feed Forge Compact and which provider transcript records remain protocol-critical;
2. keep tool invocation/result and reasoning replay envelopes intact;
3. derive Project Capsule authority from canonical accepted producers, not model-authored summary text;
4. bind capsule/source revisions to the exact run context;
5. prove byte/token/context reduction with the correct accounting truth level;
6. wire measured memory-pressure/governor behavior only from trusted runtime/device evidence;
7. run normal-agent + Local Only regressions before claiming Preview integration.

## Adjacent active ownership

At this audit point, Forge Compact governor/decision-archive work remains active in PR #126 and accounting-trust work in PR #140; Local Model Qualification/Fabric remain separate active stacks. Avoid inventing parallel authority or merging draft qualification semantics into the app early.

## Related hardening produced by this worker

Separate product branch:
`worker/GPT56-SOL-NF-V14-CAPSULE-RENDER-0810/render-framing/e1`

Product head:
`7bcbb24fccebfb42c38558d45711e89c795b2dab`

It hardens Project Capsule flattened record framing against multiline content that can visually impersonate a second `[Lx][kind][truth]...` record and adds byte-budget/legacy-decode regressions.

Exact real-package validation was executed through validation-only Actions run `31379973670` on Swift 6.3.3 / Ubuntu 24.04:

- Debug + warnings-as-errors: **70/70 PASS**
- Release + warnings-as-errors: **70/70 PASS**
- new rendered-context hardening suite: **4/4 PASS** in each configuration

This package validation does not change the integration verdict above.

## Non-claims

No physical iPhone 12 result, iOS 27 Simulator result, RAM saving, token saving, model compatibility, tokens/sec, thermal, energy, or Local Only network-isolation result is claimed by this audit.

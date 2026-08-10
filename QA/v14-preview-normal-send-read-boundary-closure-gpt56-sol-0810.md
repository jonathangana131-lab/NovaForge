# V14 Preview — Normal Send Read-Boundary Closure

Worker: `GPT56-SOL-NF-V14-CAPSULE-RENDER-0810`  
Protocol: `NF-SWARM-v14`  
Audited source base: `main@37b5305c459907917d1f27ddc7f08168a68c4bbe`  
Date: 2026-08-10

## Verdict

For the audited head, the **normal Chat composer send path is canonical AgentSystem**, and the production AgentSystem engine composition supplies `AgentSandboxReadOnlyToolExecutor` as the package `AgentEngine`'s `readOnlyExecutor`.

Therefore the previous read-boundary audit can now close the routing question for the normal basic Preview agent journey:

**Normal Chat send -> AgentSystem -> production `AgentEngine` -> pinned-fd read executor.**

The legacy `AgentRuntime.executeTool(...) -> SandboxToolExecutor` loop still exists in source and still has non-debug internal callsites, but it is not the normal `ChatView.sendPrompt()` dispatch path at this audited head.

This does not prove that every specialized/legacy/background mission path in the app is free of the old executor. It closes only the user-visible normal Chat send route requested by the polished pre-2.0 Preview.

## Source trace

### 1. ChatView declares production AgentSystem ownership

`AgentPad/Views/ChatView.swift` states that production activity comes from the canonical journal repository and process-owned `AgentSystem`. Its DEBUG streaming fixture explicitly calls `AgentRuntime` the retired runtime used only as that fixture's chunk clock.

### 2. Normal composer send calls AgentSystem presentation

In `ChatView.sendPrompt()` the production send task calls:

```swift
let disposition = await agentSystemPresentation.startConfigured(
    prompt: text,
    conversation: conversation,
    project: scopedProject,
    workspace: agentWorkspace,
    settings: settings
    // ...
)
```

The normal send does not call the legacy `AgentRuntime` tool loop directly.

### 3. Production AgentSystem composition creates the hardened read adapter

`AgentPad/Services/AgentSystemProductionComposition.swift` builds the accepted runtime and constructs:

```swift
let readExecutor = try AgentSandboxReadOnlyToolExecutor(
    workspace: environment.workspace,
    projectID: context.projectID
)
```

The resulting runtime carries that adapter as `readExecutor`.

### 4. AgentEngine receives that exact adapter as read authority

The same production composition constructs `AgentEngine` with:

```swift
readOnlyExecutor: runtime.readExecutor
```

alongside the canonical context preparer and mutation adapter.

`AgentSandboxReadOnlyToolExecutor` delegates actual content reads to `POSIXWorkspaceReadBackend`, whose descriptor-relative/no-follow design pins the workspace root and fails on path replacement instead of redirecting a read outside the pinned root.

## Updated classification

- **Normal Chat / basic Preview send:** IN APP and routed through canonical AgentSystem read authority at audited head.
- **Canonical AgentEngine read implementation:** pinned-fd `AgentSandboxReadOnlyToolExecutor` / `POSIXWorkspaceReadBackend`.
- **Legacy AgentRuntime read loop:** still present and internally callable; not the normal Chat composer send route.
- **Every specialized legacy/background path:** not established by this receipt.

## Product implication

For the basic polished Preview, there is no source-backed reason from this audit to replace the normal Chat read path: it already routes through the hardened canonical boundary. Removing or migrating the remaining legacy `AgentRuntime` executor should be treated as later cleanup unless a separate accepted Preview surface is proven to route through it.

This avoids a risky high-contention rewrite of `AgentRuntime.swift` based on a concern that does not apply to the normal Chat journey.

## Non-claims

No exploit/exfiltration claim, physical-device result, Simulator result, performance claim, mutation-boundary claim, or universal all-app-path claim is made. This is a static source-routing closure for the audited normal Chat send path.

# V14 Preview — Legacy Read Reachability Follow-up

Worker: `GPT56-SOL-NF-V14-CAPSULE-RENDER-0810`  
Protocol: `NF-SWARM-v14`  
Source base inspected: `main@37b5305c459907917d1f27ddc7f08168a68c4bbe`  
Date: 2026-08-10

This follow-up narrows one statement in `v14-preview-read-boundary-audit-gpt56-sol-0810.md`.

## Stronger source-backed finding

The path-based `SandboxToolExecutor` is not referenced only by a debug fixture. `AgentRuntime.private executeTool(...)` directly constructs it for read-only execution, and `executeTool(...)` has multiple non-debug callsites in `AgentRuntime`, including:

- the approval-resume task after an approved pending tool;
- a provider tool-call loop that parses the provider call into `ToolRequest` and executes it;
- another active provider/tool loop that marks the request as `Updating workspace` / `Inspecting workspace` and executes it.

`debugExecuteTool(...)` is an additional caller, not the sole caller.

A source search of the inspected `AgentRuntime.swift` found no `AgentSandboxReadOnlyToolExecutor` reference in that file.

Therefore it is established that **the legacy AgentRuntime execution loop itself still wires read-only tool requests through `SandboxToolExecutor`**, rather than through the pinned-fd `AgentSandboxReadOnlyToolExecutor` adapter.

## What remains unresolved

The same source explicitly calls `AgentRuntime` ownership a **legacy run** bridge while M9 moves canonical UI ownership into shared `AgentSystem`, and its recovery code separately recognizes canonical AgentSystem-owned runs.

So this follow-up still does **not** establish that every current Preview user journey reaches the legacy loop. The remaining product question is routing/composition:

- which user-visible Preview modes/providers still select legacy AgentRuntime execution;
- which select canonical AgentSystem production composition;
- whether Local AI normal-agent/tool routes still have any legacy fallback into `executeTool(...)`.

## Closure implication

The previous safe-next-rung remains correct but more focused: trace production composition from Composer/send/provider selection to either AgentSystem or legacy AgentRuntime. If any accepted Preview route can enter the legacy loop for read tools, migrate that route to the typed pinned-fd read executor (or remove the legacy loop if obsolete) and exercise the existing validation-to-open interposition adversarially.

No exploit or exfiltration claim is made. This is a product-architecture authority-boundary finding.

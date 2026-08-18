# V14 Preview Composer Stop Source Contract

## Purpose

The Preview Constitution requires Stop/cancel recovery to remain truthful. Recent runtime work makes user cancellation distinct from failure and protects cancellation/reentry arbitration, but those lifecycle tests can stay green if the visible Composer Stop control is later disconnected from one of the real product cancellation paths.

This contract adds one narrow source-composition tripwire across the current product seam:

`Composer Stop control -> ChatView stopActiveRun -> canonical orchestration / canonical group cancel command / hosted-canary / legacy AgentRuntime branches`

The legacy `AgentRuntime` branch has an additional accepted invariant: its resumable user cancellation remains `.cancelled` with neutral `Paused` lifecycle presentation rather than failure-only `Blocked` semantics.

The contract intentionally does **not** claim that every Stop branch shares the legacy runtime's `Paused` terminal copy. Canonical AgentSystem activity owns its own accepted state/presentation contract and is guarded here only for cancellation-command wiring.

## Guarded source facts

`scripts/verify_v14_preview_composer_stop_contract.py` fails closed unless the current tree preserves all of the following:

- `ComposerLiveRunRail` still owns a visible `Stop` button with accessibility label `Stop generating` and identifier `composerStopButton`;
- ChatView's live-run rail routes `stop:` through the centralized `stopActiveRun` handler;
- active canonical orchestration cancels through `agentSystemPresentation.cancelOrchestration(scope:)`;
- a normal canonical AgentSystem activity group retains the accepted `group.cancelCommand` path through `handleActivityCommand(...)`;
- the DEBUG hosted text canary retains its own bounded stop path;
- the legacy/runtime-owned bridge reaches `AgentRuntime.stopGenerating(context:)`;
- that legacy runtime stop requests cancellation, cancels the tracked task, clears the live stream, records `Paused by user` / `runPaused`, and settles the working session as `.cancelled`;
- that legacy cancellation lifecycle calls `runCancelled`, and its Live Activity cancellation presentation remains neutral `Paused` / `isWorking: false` rather than failure-only `Blocked` semantics.

The dedicated workflow runs on changes to any guarded source path, the verifier, this receipt, or the workflow itself.

## Evidence boundary

A green contract is **source-composition evidence only**. It proves neither the canonical AgentSystem cancellation terminal presentation nor canonical retry/continuation policy. It also does not prove that a Simulator tap succeeds, that the control is visually reachable on iPhone 12, that VoiceOver can activate it, that a real hosted/local provider aborts promptly, that tool mutation cancellation is rollback-safe, or that the next user run succeeds after cancellation.

Those remain executable Preview acceptance responsibilities. This guard exists so source drift cannot silently sever the visible Stop control from a real cancellation path while narrower runtime tests remain green, and so the legacy runtime fallback cannot regress user cancellation back into failure presentation.

## Construction identity

- Worker: `GPT56-SOL-NF-V14-PREVIEW-COMPOSER-STOP-CONTRACT-0814`
- Construction base: `main@f319f6ceee5513b46d87e948b7a6ffb993e879ac`
- Scope: three additive guard/QA/workflow files only; no production Swift mutation.

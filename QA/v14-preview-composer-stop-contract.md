# V14 Preview Composer Stop Source Contract

## Purpose

The Preview Constitution requires Stop/cancel recovery to remain truthful. Recent runtime work makes user cancellation distinct from failure and protects cancellation/reentry arbitration, but those lifecycle tests can stay green if the visible Composer Stop control is later disconnected from the cancellation path.

This contract adds one narrow source-composition tripwire across the current product seam:

`Composer Stop control -> ChatView stopActiveRun -> canonical AgentSystem / hosted-canary / AgentRuntime cancellation branches -> neutral Paused lifecycle presentation`

## Guarded source facts

`scripts/verify_v14_preview_composer_stop_contract.py` fails closed unless the current tree preserves all of the following:

- `ComposerLiveRunRail` still owns a visible `Stop` button with accessibility label `Stop generating` and identifier `composerStopButton`;
- ChatView's live-run rail routes `stop:` through the centralized `stopActiveRun` handler;
- active canonical orchestration cancels through `agentSystemPresentation.cancelOrchestration(scope:)`;
- the DEBUG hosted text canary retains its own bounded stop path;
- the legacy/runtime-owned bridge reaches `AgentRuntime.stopGenerating(context:)`;
- that runtime stop requests cancellation, cancels the tracked task, clears the live stream, records `Paused by user` / `runPaused`, and settles the working session as `.cancelled`;
- the cancellation lifecycle calls `runCancelled`, and the Live Activity cancellation presentation remains neutral `Paused` / `isWorking: false` rather than failure-only `Blocked` semantics.

The dedicated workflow runs on changes to any guarded source path, the verifier, this receipt, or the workflow itself.

## Evidence boundary

A green contract is **source-composition evidence only**. It does not prove that a Simulator tap succeeds, that the control is visually reachable on iPhone 12, that VoiceOver can activate it, that a real hosted/local provider aborts promptly, that tool mutation cancellation is rollback-safe, or that the next user run succeeds after cancellation.

Those remain executable Preview acceptance responsibilities. This guard exists so source drift cannot silently sever the visible Stop control from the cancellation semantics while narrower runtime tests remain green.

## Construction identity

- Worker: `GPT56-SOL-NF-V14-PREVIEW-COMPOSER-STOP-CONTRACT-0814`
- Construction base: `main@f319f6ceee5513b46d87e948b7a6ffb993e879ac`
- Scope: three additive guard/QA/workflow files only; no production Swift mutation.

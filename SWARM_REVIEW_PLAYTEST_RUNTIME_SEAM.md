# V14 autonomous playtest ↔ Forge Runtime semantic seam review

Worker: `GPT56-NF-V14-PLAYTEST-RUNTIME-8A8K`  
Reviewed playtest PR: #103 at `ee4ed30a523f201bf30bad1adf603b3d9ddd0826`  
Reviewed runtime PR: #98 at `99d584d85415a0f02eb0f5525c17b99314999e97`

## Closure finding

#103 correctly requires a public `ForgePlaytestExecutionBinding` that reproduces the **entire planned trace** and points at one `.runtimeExecution` evidence reference. #98 correctly produces host-authorized, session/checkpoint/project/sequence-bound semantic dispatch receipts.

However, the two semantic action vocabularies are not currently losslessly compatible, and neither core proves that every planned playtest step was represented by an accepted host dispatch receipt.

### Action coverage mismatch

`ForgePlaytestAction` (#103):
- `axis(controlID:value:)`
- `button(controlID:phase:)` with press/release
- `pointer(controlID:x:y:phase:)` with begin/move/end/cancel
- `wait`
- `pause`
- `resume`
- `restart`
- `save`
- `reload`
- `escape`

`ForgeRuntimeSemanticInteractionKind` (#98):
- `control.activate`
- `text.enter`
- `action.set-value`
- `gesture.perform` with semantic gesture ID + duration
- `runtime.restart`

Only `axis -> action.set-value` and `restart -> runtime.restart` have an obvious exact mapping. `button` loses press/release semantics if reduced to `control.activate`; pointer x/y/phase cannot be reconstructed from opaque gesture ID + duration; wait/pause/resume/save/reload/escape have no canonical exact host-dispatch representation in the reviewed runtime contract.

## Why this matters

A bridge that merely receives a `.runtimeExecution` receipt ID and the full planned trace can still claim the trace was executed even if its runtime adapter dropped, approximated, or transformed unsupported steps. Full-trace structural equality inside #103 proves which trace was *claimed*, not that every step was faithfully authorized and delivered by #98.

This is especially important for Save/Reload Tester, Chaos Tester, New Player, and goal-path acceptance: silently dropping release/reload/pointer/lifecycle steps could produce false positive playtest evidence.

## Required integration contract

Before runtime execution evidence can satisfy #103, the canonical adapter should fail closed unless it can produce a deterministic per-step execution projection that binds:

- exact playtest project + source revision + journey + trace;
- exact host runtime session ID;
- exact runtime version;
- exact checkpoint ID;
- one mapping result for every planned step;
- exact ordered Forge Runtime receipt identity for every dispatching step;
- explicit host-observed wait/timing evidence for non-dispatch `wait` steps if timing is semantically required;
- no dropped or implicit unsupported action;
- no receipt from another session/checkpoint/runtime version;
- only delivery dispositions that the journey policy accepts.

For each playtest action, the mapping result should be one of:
1. exact canonical runtime dispatch mapping;
2. exact host lifecycle mapping owned by the runtime host;
3. explicit non-dispatch timing/control primitive with host evidence;
4. unsupported -> journey cannot claim runtime execution.

Do **not** make the bridge invent a lossy mapping merely to cover every enum case.

## Contract convergence options

The canonical owners should choose one authority direction rather than creating a third semantic vocabulary:

- expand Forge Runtime's host semantic interaction model until every accepted playtest action has exact semantics; **or**
- narrow/normalize ForgePlaytestAction to the canonical runtime semantic primitives plus explicit host lifecycle/timing primitives; **or**
- add a typed adapter-owned execution transcript that proves each higher-level playtest action expands into an exact ordered sequence of lower-level runtime receipts without information loss.

Whatever path is chosen, #103's current single opaque `.runtimeExecution` reference should not by itself establish per-step runtime execution authenticity.

## Additional execution identity note

#98's `ForgeRuntimeAutomationSession` carries `runtimeVersion`, but `ForgeRuntimeSemanticInteractionReceipt` carries session/project/checkpoint/sequence/interactions and **not runtimeVersion directly**. A canonical playtest adapter should therefore validate receipts against the exact host-owned session object (or a producer receipt that cryptographically/immutably binds the session to its runtime version), not accept standalone serialized delivery receipts as enough execution identity.

## Truth boundary

This review does not claim either core is wrong in isolation. Both PRs state that the missing runtime adapter remains future work. The finding is that the adapter cannot be implemented truthfully as a simple receipt-ID handoff with the present action surfaces; semantic coverage and per-step execution binding must be closed before Full Forge can say it actually played the planned trace.

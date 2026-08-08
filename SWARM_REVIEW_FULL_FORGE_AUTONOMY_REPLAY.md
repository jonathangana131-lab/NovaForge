# V14 Full Forge autonomy policy review — replay and budget lineage

Worker: `GPT56-NF-V14-COMPLETE-8A8F`  
Reviewed PR: #119  
Reviewed head: `ff29bd2e18eb07ac59c8fae4ca12f9e7146e8492`

## P1 — persisted proceed decisions are replayable

`ForgeAutonomyDecision` is `Codable`. Decode recomputes the disposition from the **serialized** `ForgeAutonomyBudget` and **serialized** `ForgeAutonomyObservation`, then accepts the decoded decision when those old inputs still imply the serialized output.

That protects against directly editing `proceed` into a decision whose embedded observation already requires pause, but it does not establish freshness. A previously valid serialized `proceed` can still decode as valid after:

- action/elapsed counters advance;
- thermal or memory pressure worsens;
- the user requests pause/cancel;
- a material decision/policy approval/external blocker appears.

The evaluator never sees the host's current observation at decode/consumption time.

### Required boundary

Treat the derived scheduling decision as transient/non-persistable, **or** bind it to an immutable host observation receipt/monotonic sequence and require the consumer to compare that exact observation authority with current host state before scheduling another action.

Re-running the evaluator on stale embedded inputs is tamper resistance, not freshness/replay resistance.

## P1/P2 — hard mission budgets can become checkpoint-resettable

`ForgeAutonomyBudget` describes hard elapsed/action ceilings, but its source comment scopes those bounds to one authority epoch. Near-limit policy emits `checkpointThenProceed`; canonical Mission checkpointing advances authority. Nothing in this core binds `elapsedMilliseconds` / `actionsUsed` to a mission-global counter lineage or prevents a new checkpoint/authority snapshot from supplying zeroed counters.

If an adapter resets counters when authority changes, repeated checkpointing can turn a nominal hard Full Forge mission ceiling into an unbounded sequence of fresh epochs.

### Required boundary

If these are intended as hard mission budgets, preserve cumulative monotonic consumed totals across checkpoint/authority changes, or bind observations to a durable budget-lineage ID plus consumed totals that cannot reset without explicit user policy revision.

## P2 — elapsed hard ceiling also needs an execution deadline

The elapsed ceiling is evaluated only immediately before scheduling. A long-running action can cross the wall-clock maximum after dispatch. A genuinely hard elapsed budget therefore still requires the host executor to enforce a deadline/cancellation boundary using the remaining time; the pre-dispatch projection alone cannot guarantee the ceiling.

These findings do not require `ForgeAutonomyCore` to read iOS telemetry. They require host freshness, counter lineage, and execution-deadline semantics to remain non-bypassable when this policy becomes actual scheduling authority.

# V14 Preview effort-budget review — PR #216

Reviewed PR: #216 `[V14 Preview] Make five-stop effort change the accepted run budget`
Reviewed head observed: `1b5adc1b82c8228451aff01cc57b1d2694987ddd`
Reviewed against live main observed: `37b5305c459907917d1f27ddc7f08168a68c4bbe`
Reviewer: GPT-5.6 Sol
Date: 2026-08-10

## Result

No code-level blocker found in the accepted-budget authority/enforcement path. Promotion should still wait for exact-head macOS/Xcode CI because this review did not execute the registered app/unit targets.

## Enforcement trace

The proposed Preview policy derives a bounded `AgentBudget` from the existing persisted reasoning/orchestration preference rather than creating a second user-facing effort authority.

The accepted request path stores that budget in `AgentRunContext.initialBudget`. On `.runAccepted`, `AgentReducer` copies `payload.context.initialBudget` into live reducer state. The reducer then hard-gates the three dimensions changed by this PR:

- `.modelRequestStarted` requires available `iterations` and `providerAttempts`, then consumes one of each;
- `.toolProposed` requires available `toolInvocations`, then consumes one;
- exhausted dimensions reject the event before the corresponding new work is accepted.

This means the five-stop values are reducer-enforced work capacity, not presentation-only metadata.

## Budget-shape checks

`AgentBudgetLimits.standard` is currently:

- iterations 32
- provider attempts 48
- retries 8
- tool invocations 64
- input tokens 1,000,000
- output tokens 250,000
- elapsed 3,600,000 ms
- cost 100,000,000 microunits
- child runs 16
- child depth 4

The PR intentionally changes only iterations/provider attempts/tool invocations and preserves the other conservative ceilings. The current Preview mapping is monotonic across those work dimensions:

- Low: 8 / 12 / 24
- Medium: 32 / 48 / 64 (exact standard)
- High: 48 / 72 / 96
- Extra High: 64 / 96 / 128
- Ultra (`.ultraCode` internal state): 128 / 192 / 256

The unchanged child-run ceiling is not a blocker for the currently proven Ultra orchestration shape: 16 child runs / depth 4 is above the existing three-worker + integrator canary topology. Raising child-run authority without a stronger product requirement would expand autonomous fan-out risk unnecessarily.

## Adversarial checks performed

- Cleared a suspected caller-budget override regression: the old `standardBudget` was a private fresh-run-factory constant, not a caller-supplied accepted budget.
- Legacy `.ultra` remains mapped to Extra High semantics rather than the new top stop.
- `.standard + .max` is treated as Extra High; only `.ultraCode` identifies the current top Preview effort stop, preventing stale state from silently self-promoting.
- `AgentEngineConfiguration.maximumModelRounds` remains a separate finite safety ceiling; the PR does not replace it with preference authority.
- Token/time/cost/child ceilings remain finite and unchanged, so Ultra is stronger in loop/tool capacity without becoming unbounded.

## Remaining gate

At review time PR #216 reported its dedicated Preview effort contract green on an earlier exact head and the current full CI run as queued. Because the PR head advanced during the review and GitHub REST read quota was exhausted immediately afterward, this reviewer did not independently observe green macOS/Xcode CI for exact head `1b5adc1b...`.

Do not merge based on this receipt alone. Merge only after exact-head registered-target CI is green and the branch is still mergeable against current main. No Simulator screenshot, accessibility, performance, or physical-device acceptance is claimed by this backend review.

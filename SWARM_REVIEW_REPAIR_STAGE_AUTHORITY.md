# V14 Repair stage-authority review

Worker: `GPT56-NF-V14-GO-8A08`  
Reviewed PR: `#107`  
Reviewed head: `e35cb26a78dc85f169e39d319842e5bc52159e8b`

## P1 — staged verification is checked as a final receipt set, not enforced as a repair state machine

The package has a useful deterministic policy shape, but its advertised verification sequence:

`focused test -> full journey -> visual regression -> accessibility -> performance -> accept`

is not represented as durable transitions.

`RepairAttempt` contains both the before/after patch scorecards **and** all five optional `RepairVerificationReceipts`. `RepairCampaign.assess()` only checks which receipt fields happen to be non-nil on the latest attempt. There is no transition API that consumes the current `nextAction` and attaches one newly accepted verification result to that same attempt.

The only mutation helper is `RepairCampaign.appending(_:)`, which appends an entirely new `RepairAttempt`. Conversely, the public `RepairCampaign` / `RepairAttempt` initializers allow a caller to construct the latest attempt with every verification receipt already present.

Therefore a campaign can jump directly from a caller-built attempt to `.acceptCandidate` without any package-level evidence that the staged actions were requested or completed in order.

### Concrete jump

The existing `acceptanceRequiresAllConfiguredReceipts` test demonstrates the shortcut: it constructs ordinal-1 `RepairAttempt` with `focusedTest`, `fullJourney`, `visualRegression`, `accessibility`, and `performance` all already populated, builds the campaign, and immediately expects `.acceptCandidate`.

That proves the current policy enforces **receipt-field completeness**, not the claimed staged verification transition sequence.

## P1 — verification receipt identity is not bound to the candidate/attempt subject

`RepairVerificationReceipts` stores only opaque `RepairReceiptID` values. The type itself carries no project ID, defect ID, attempt ID, source revision, candidate revision, checkpoint, evidence kind, or stage ordering information.

Even if a future canonical adapter authenticates the receipt IDs, the RepairCore value no longer contains enough subject identity to independently prove that the focused/full/visual/a11y/performance receipts belong to this exact candidate revision and repair attempt rather than another run/revision.

A disciplined adapter can enforce this convention before construction, but the current `acceptCandidate` value must not be treated downstream as evidence-backed repair acceptance unless that stronger binding is preserved by an unforgeable adapter/capability.

## P1 — repair-attempt revision lineage is not validated

Campaign validation enforces project/defect/checkpoint identity, attempt-ID uniqueness, ordinal sequence, and `sourceRevisionID != candidateRevisionID`, but it does not bind attempt revision lineage.

For example, attempt 1 may be `revision-A -> candidate-B` and attempt 2 may be `unrelated-X -> candidate-Y`; the campaign accepts the sequence as long as ordinals are 1, 2 and other IDs match. Likewise the first attempt is not required to start from `defect.discoveredRevisionID`, nor is there an explicit accepted restore transition that explains a later source revision change.

This matters because a final `.acceptCandidate` can otherwise refer to a candidate whose relation to the defect-bearing source / previous repair state is not represented.

## Required closure

Either explicitly downgrade the package to a **stateless policy projection** whose `RepairAssessment` is non-authoritative and whose integration adapter owns all sequencing/receipt subject/lineage truth, or encode the intended repair state machine in the contract.

For the stronger Full Forge target, prefer:

- split patch attempt state from verification-stage state;
- add an explicit transition that consumes the current requested stage plus an already-authenticated producer result and returns the next state;
- bind each accepted verification receipt to exact project + defect + attempt + candidate revision + evidence stage (and producer identity where material);
- prevent later-stage acceptance before required earlier-stage acceptance;
- preserve a canonical revision lineage / explicit restore event so attempt N cannot silently jump to an unrelated source revision;
- make downstream executable `acceptCandidate` authority non-Codable/non-self-mintable and derive it only after the trusted transition history is complete;
- add adversarial regressions for all-receipts-at-once jump, cross-candidate receipt replay, out-of-order stage replay, and unrelated attempt revision chain.

The existing useful policy math should remain: Pareto regression rollback, bounded attempts, non-improvement escalation, duplicate IDs/ordinals, configured stage requirements, and archive assessment recomputation.

## Truth boundary

This review does not claim the opaque receipt IDs are fake and does not challenge the reported 20/20 debug/release package result. It identifies a state-transition and subject-binding gap not covered by those tests. No generated-project repair, runtime execution, Simulator/device, visual, accessibility, or performance result is claimed.

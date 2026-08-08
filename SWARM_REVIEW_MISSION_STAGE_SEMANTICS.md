# V14 Mission Engine review — accepted-stage semantic identity

Worker: `GPT56-NF-V14-COMPLETE-8A8F`  
Reviewed PR: #110  
Reviewed head: `25e1b65c7af2f63f340bcc33505774492794da89`

## P1 finding

`ForgeMissionState.replaceStageGraph(_:)` preserves accepted execution truth by `MissionStageID` + status, but it does not preserve the accepted stage's semantic definition.

A completed stage can therefore be relabeled while retaining old receipts:

1. stage `S` is accepted as `kind=.implement`, title `Implement`, with worker/stage evidence;
2. a higher graph revision reuses `stageID=S` and `.completed` status but changes the stage to e.g. `kind=.accessibility`, title `Accessibility acceptance`;
3. `replaceStageGraph` accepts the replacement because the surviving-stage guard checks only status equality;
4. `MissionStageEvidence`, `MissionAcceptedWorkerReceipt`, decision and recovery records remain bound only to `stageID`;
5. a fresh checkpoint can then bind the relabeled graph and completion can count that stage as completed.

This lets a graph revision repurpose accepted receipts for materially different work without rerunning the stage.

## Required invariant

Once a stage has accepted execution history, graph replacement should preserve its semantic identity at minimum:

- `kind`;
- canonical `title`;
- `required`;
- hard `dependencies`.

`order` may remain replannable if intentionally treated as non-semantic. If the work itself changes, mint a new `MissionStageID` and preserve the prior accepted stage as history rather than relabeling it.

## Regression

Add an adversarial test that:

- completes an `.implement` stage with evidence;
- attempts a higher graph revision reusing its ID/status as `.accessibility`;
- expects `replaceStageGraph` to fail closed;
- verifies accepted evidence remains attached only to the original semantic stage.

This protects the V14 requirement that evidence belongs to the exact accepted work and prevents a model/plan revision from laundering old receipts through a stable ID.

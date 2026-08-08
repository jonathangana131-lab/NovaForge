# ForgePerformanceCore

`ForgePerformanceCore` is the machine-readable performance acceptance truth layer for NovaForge Full Forge missions.

It does not collect metrics or claim that a generated project is fast. It evaluates host-accepted performance budgets against host-accepted measurement batches and returns a derived, non-persistable verdict.

## Authority model

A performance target binds the exact project/source/mission/runtime/environment/measurement-protocol/budget revision. The budget and measurement batch each carry opaque receipt identifiers, but identifiers are not authority by themselves.

`ForgePerformanceEvaluator.evaluate` therefore requires two independent host-provided trust sets:

- accepted budget-authority receipt IDs;
- accepted measurement-batch receipt IDs.

Serialized or model-provided data cannot self-authorize merely by spelling one of those receipt fields. The host/Mission adapter is responsible for authenticating receipts and for ensuring a batch receipt covers the complete accepted run set rather than a cherry-picked subset.

## Acceptance semantics

Every required run must contain every budgeted metric with at least the required sample count. Missing metrics, missing runs, and insufficient samples block acceptance. When inputs are complete, evaluation uses the worst observed value across the accepted run set for each metric; a bad run cannot be averaged away. A metric above its maximum budget fails acceptance.

The evaluator result is deliberately non-`Codable`. Archives persist only validated raw budget and measurement inputs; verdicts must be recomputed with fresh host trust.

## Environment truth

Physical-device and Simulator targets are distinct. Hardware identifier, OS version, and OS build are part of target identity. Simulator evidence cannot satisfy a physical-device target.

This package contains no iPhone 12 performance result, no FPS/frame-time/memory/thermal/energy claim, and no measurement harness. Exact-device qualification remains external evidence.

## Completion integration seam

A narrow host adapter may map an accepted `ForgePerformanceEvaluation` plus its trusted receipt provenance into the canonical Completion Constitution's performance evidence slot. The adapter must not move budget selection or receipt authentication into model output, and a model statement such as `fast`, `passed`, or `done` is never performance evidence.

## Package validation checkpoint

Exact published source/test bytes at the authority-hardening checkpoint were validated with Swift 6.2.1 on Linux:

- debug SwiftPM tests with warnings-as-errors: 25/25 passed;
- release SwiftPM tests with warnings-as-errors: 25/25 passed;
- release SwiftPM build with warnings-as-errors: passed;
- diff check: clean.

Validated blobs:

- `Package.swift`: `12ecd9e52a6794d96b72adabf16a058af7ed71bb`
- `ForgePerformanceCore.swift`: `ae03b7d1b0547fa2e191ff8187cf625cd477d8f8`
- `ForgePerformanceCoreTests.swift`: `40b50c541fceb98e508308309f281f2279559cad`

This is package-level evidence only. It is not Simulator or physical-device runtime evidence.

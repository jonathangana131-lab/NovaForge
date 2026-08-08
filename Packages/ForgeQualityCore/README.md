# ForgeQualityCore — V14 numeric quality gate

`ForgeQualityCore` is an additive pure-Swift numeric acceptance seam for V14 Full Forge.
It is **not** a Completion Constitution, Mission Engine, evidence authenticator, or runtime producer.

## Authority position

Live Completion Constitution PR #111 is the machine-readable definition-of-done authority beneath the canonical Mission Engine. Its current exact target identity is:

`missionID + projectID + sourceRevision + constitutionRevision + constitutionReceiptID`

`ForgeQualityCompletionTarget` intentionally mirrors that identity. A numeric policy is additionally bound to one exact Completion criterion ID and one opaque `policyAuthorityReceiptID`.

The serialized policy cannot authorize itself. `ForgeQualityEvaluator.evaluate` requires the caller to supply both:

1. the separately trusted numeric-policy authority receipt ID; and
2. the currently accepted exact Completion target.

A mismatch fails closed.

### Current integration gap

PR #111 defines typed `performance` / `accessibility` criteria and typed evidence slots, but it does **not** currently encode numeric threshold values such as p95 frame time or p95 input latency.

Therefore a canonical adapter still needs an authority-backed source for the accepted numeric quality policy. This package deliberately does not invent or infer those thresholds. Until that policy authority exists, a generated project's numeric quality gate cannot truthfully be promoted into an accepted #111 performance/accessibility receipt.

## Intended composition

`accepted numeric policy + authenticated canonical producer measurements`

`-> ForgeQualityCore deterministic evaluation`

`-> canonical adapter emits exact-target #111 performance/accessibility evidence only after pass`

`-> ForgeCompletionCore evaluates the whole Constitution`

`-> canonical Mission Engine consumes the result as one completion input`

Adjacent producer lanes include autonomous playtest #103, Forge Runtime, ProjectTesting, accessibility and performance harnesses. Opaque producer receipt IDs remain references; authenticity belongs to the canonical adapters/producers.

## Gate semantics

- missing required measurement -> `blocked`;
- a physical-device-only target with only Simulator evidence -> `blocked`;
- measured threshold violation -> `failed`;
- a known failure wins over a concurrent missing-evidence blocker so repair can act on the real defect;
- accepted receipt IDs are emitted only when every accepted target passes;
- run-wide and journey-scoped targets are distinct, so evidence from one #103 journey cannot satisfy another;
- current metrics are lower-is-better and reject `.atLeast` comparator inversion;
- persisted snapshots store policy + measurements, not a trusted verdict; assessment must be re-derived with current external authority.

## Exact direct validation checkpoint

Worker: `GPT56-NF-V14-QUALITY-8C8A`  
Lane: `completion-quality-budget-gate`  
Control: issue #23  
Feature base: `main@d70584bd4f3a5a972067dc12c91873e864ab2ae1`

Swift 6.2.1 Linux on exact published Swift/package blobs before this README-only commit:

- `swift test -Xswiftc -warnings-as-errors` -> **23/23 passed**
- `swift test -c release -Xswiftc -warnings-as-errors` -> **23/23 passed**
- `swift build -c release -Xswiftc -warnings-as-errors` -> **PASS**
- `git diff --cached --check` -> **PASS**

Exact validated code blobs:

- `Package.swift` `8e4a0a16fd6a11426b3189b0f822515daa75fc58`
- `ForgeQualityCore.swift` `9fb4ed91a61d3090081260354d71c5355f36fb7f`
- `ForgeQualityCoreTests.swift` `919b0561e270b1f9785b55152631e604c69b96db`

At the final workflow check, the feature head had no pull-request-triggered workflow run because GitHub secondary content-creation throttling prevented draft PR creation. Current package-gate recovery PR #118 had both generic CI and the dynamic package-contract workflow queued, so no hosted package proof is claimed here.

## Non-claims

No generated-project runtime performance or accessibility result is proved by this package. No iPhone 12/iOS 27 Simulator or physical-device FPS, latency, memory, energy, thermal, or accessibility claim is made. No app UI, Xcode project, provider, Local AI, Forge Compact, Runtime, Mission, #111, #103, shared CI, or Voltline path is modified by this lane.

## Next closure rung

Build the canonical adapter only after the numeric-policy authority is defined. It should authenticate the accepted numeric policy, convert exact current-run producer receipts into `ForgeQualityMeasurement`, evaluate this gate, and emit the corresponding exact-target #111 evidence only when the derived result passes. Real generated-project Simulator/device runs remain required for product acceptance.

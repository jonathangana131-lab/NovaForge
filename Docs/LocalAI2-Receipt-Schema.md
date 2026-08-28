# NovaForge Local AI 2.0 receipt schema

This is the normative receipt contract for Local AI 2.0 acceptance evidence. It is
additive to the shipped v1 corpus decoder: the resource remains
`schemaVersion: 1`, while `receiptContract.schemaVersion: 2` describes the
receipt that a benchmark runner must write. A runner may not turn a missing
measurement into a zero or an estimate.

## Envelope

Every receipt is one JSON object with these top-level fields:

| Field | Required value | Meaning |
| --- | --- | --- |
| `schemaVersion` | `2` | Receipt contract version. |
| `receiptKind` | `local_ai_benchmark` or `local_ai_evaluation` | Distinguishes a timing probe from a corpus run. |
| `receiptID`, `runID`, `recordedAt` | Non-empty ID, run ID, ISO-8601 timestamp | Stable identity and provenance. |
| `executionClass` | `simulator`, `generic_build`, `physical`, or `unavailable` | The strongest evidence class actually established. |
| `availability` | `verified`, `partial`, `not_run`, or `unavailable` | Whether the requested measurement was obtained. |
| `unavailableReason` | Required when unavailable or partial | Human-readable reason, including the blocked prerequisite. |
| `claimsAllowed` | Boolean | Must be `false` for `generic_build` or `unavailable` runtime claims and for any receipt without a matching run. |

`executionClass` is not inferred from the target name. A generic iOS
arm64 build proves compilation only. A simulator run proves simulator
behavior only. A physical result requires the device identifier and a real
physical run in the same receipt. An unavailable receipt is still valuable
evidence of a failed admission or missing prerequisite, but is never a
success result.

## Required raw sections

The following sections are required even when individual measurements are
unavailable. Values must be captured from the run rather than reconstructed
from a catalog description.

| Section | Required raw fields |
| --- | --- |
| `device` | `rawModelIdentifier`, `displayName`, `osDeviceIdentifier`, `architecture`, `isSimulator`, `isPhysicalDevice` |
| `model` | `id`, `immutableRevision`, `quantization`, `artifactSHA256`, `artifactBytes` |
| `operatingSystem` | `name`, `version`, `build` |
| `build` | `sourceCommit`, `appVersion`, `buildNumber`, `configuration`, `sdk`, `xcode`, `appSHA256` |
| `engine` | `type`, `engineRevision`, `backend`, `wrapperRevision`, `executionLocation` |
| `generation` | `contextTokens`, `maximumOutputTokens`, `sampling` |
| `sampling` | `temperature`, `topP`, `topK`, `minP`, `seed`, `repetitionPenalty` (use `null` only when the engine does not expose it) |
| `load` | `cold`, `warm`, and `postUnloadRecovery` attempt records |
| `performance` | `promptTokensPerSecond`, `timeToFirstTokenSeconds`, `decodeTokensPerSecond`, `usefulTokens`, `totalDurationSeconds` |
| `resources` | `peakMemoryBytes`, `thermalBefore`, `thermalAfter`, `thermalMax`, and `batteryImpact` |
| `lifecycle` | background/foreground and memory-warning outcome, unload outcome, and active-generation count after the run |
| `cancellation` | prefill and decode cancellation outcome, cancellation latency, lease release, and unload outcome |
| `quality` | corpus ID and SHA-256, passed/total cases, score, failure reasons, and per-case outputs or output hashes |
| `artifactHashes` | app, model, corpus, log, screenshot/trace when present, and source commit binding |

Each load attempt records `attempted`, `available`, `startedAt`,
`completedAt`, `durationSeconds`, `modelResidentBefore`, `modelResidentAfter`,
and `reason`. The cold attempt must begin after unload. The warm attempt must
reuse the same model and prefix. `postUnloadRecovery` must prove that a later
load works after cancellation or lifecycle eviction; it is not interchangeable
with warm reuse.

`promptTokensPerSecond` is required when canonical prompt-token timing is
exposed. Otherwise it is `null` with a reason such as
`engine_does_not_expose_prefill_tokens`; a high-level response estimate is not
prompt speed. `usefulTokens` is tokenizer-reported output after garbage,
over-limit repetition, and cancellation-tail filtering. Character counts are
not useful-token counts.

`batteryImpact` contains raw `levelBefore`, `levelAfter`, `isMonitoringEnabled`,
and `measurementStatus`; `deltaPercentagePoints` is derived only when both
levels are valid. Thermal state records the raw before/after state and the
maximum state observed across the entire attempt, not only the final sample.

## Minimal shape

The following is a shape example, not benchmark evidence. `null` values must
be accompanied by an availability reason in the owning section.

```json
{
  "schemaVersion": 2,
  "receiptKind": "local_ai_evaluation",
  "executionClass": "simulator",
  "availability": "verified",
  "claimsAllowed": false,
  "device": {"rawModelIdentifier": "iPhone13,2", "isSimulator": true, "isPhysicalDevice": false},
  "model": {"id": "Qwen/...Q4_K_M", "immutableRevision": "<revision>", "quantization": "Q4_K_M", "artifactSHA256": "<sha256>"},
  "operatingSystem": {"name": "iOS", "version": "<version>", "build": "<build>"},
  "build": {"sourceCommit": "<commit>", "appVersion": "<version>", "buildNumber": "<build>", "configuration": "Debug", "sdk": "<sdk>", "xcode": "<xcode>", "appSHA256": "<sha256>"},
  "engine": {"type": "llamaCpp", "engineRevision": "<revision>", "backend": "cpu", "wrapperRevision": "<revision>", "executionLocation": "local"},
  "generation": {"contextTokens": 2048, "maximumOutputTokens": 160, "sampling": {"temperature": 0, "topP": 1, "topK": 0, "minP": 0, "seed": 0, "repetitionPenalty": null}},
  "load": {"cold": {}, "warm": {}, "postUnloadRecovery": {}},
  "performance": {"promptTokensPerSecond": null, "timeToFirstTokenSeconds": null, "decodeTokensPerSecond": null, "usefulTokens": 0, "totalDurationSeconds": null},
  "resources": {"peakMemoryBytes": null, "thermalBefore": "nominal", "thermalAfter": "nominal", "thermalMax": "nominal", "batteryImpact": {}},
  "lifecycle": {},
  "cancellation": {},
  "quality": {"corpusID": "LocalAI2Corpus.v1", "corpusSHA256": "<sha256>", "passedCaseCount": 0, "totalCaseCount": 0, "score": 0, "failureReasons": []},
  "artifactHashes": {"appSHA256": "<sha256>", "modelSHA256": "<sha256>", "corpusSHA256": "<sha256>"}
}
```

## Evidence gates

| Claim | Minimum evidence |
| --- | --- |
| Corpus quality passed | `local_ai_evaluation` receipt with matching corpus SHA, model SHA, per-case results, and `score`; no physical claim follows from this alone. |
| Simulator behavior | Matching `executionClass: simulator` receipt with simulator identifier, app hash, model hash, and run output. Label every result simulator-only. |
| Generic build | Matching `executionClass: generic_build` build artifact and hash. This can support compile/link claims only, never inference, throughput, memory, thermal, battery, or Core AI success. |
| Physical-device behavior | Matching `executionClass: physical` receipt with raw device identifier, app/model/corpus hashes, and completed physical run. Simulator or generic-build evidence cannot substitute. |
| Core AI success | Matching physical Core AI receipt with pinned package revision, AOT asset hash, engine/backend, supported hardware, and corpus results. An import, catalog entry, generic build, or unavailable receipt is not success evidence. |
| Candidate becomes default | Physical receipt(s) covering the required cold/warm, 128-useful-token, lifecycle/cancellation, memory, thermal, battery, and quality gates, plus a comparison receipt for the incumbent. |

The current app still writes legacy timing/evaluation receipts. Those formats
do not create physical or Core AI evidence merely by existing; this contract
defines the evidence needed to make future conclusions auditable.

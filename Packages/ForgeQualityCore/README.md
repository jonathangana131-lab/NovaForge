# ForgeQualityCore

Pure-Swift V14 quality-budget truth for generated-project completion.

This package evaluates explicit performance/accessibility targets against exact-run measurements. It does **not** measure a device, authenticate runtime/accessibility producers, or complete a mission. Candidate policy/measurement/batch values are Codable for durable transport, while accepted policy, current-run, and producer **whole-batch** trust are non-Codable whole-subject bindings with module-internal construction. A persisted or model-shaped receipt cannot mint a passing quality gate by itself.

The quality subject binds current Mission/Completion target plus a host-authenticated current run carrying exact project/source/checkpoint/runtime/host-build/run/environment/device/OS identity. Targets encode metric direction, minimum sample counts, run/journey scope, exact measurement-protocol identity, and optional exact environment requirements. Journey scope includes the canonical journey-definition digest. Missing/undersampled/environment-mismatched evidence blocks; a known threshold violation fails even when another target is missing.

Public acceptance consumes one authenticated measurement batch for the exact run/protocol rather than independently trusted scalar observations. One canonical producer receipt may attest multiple metrics inside that batch. The evaluator rejects duplicate metric/scope observations and impossible same-population frame percentile ordering (`p95 > p99`, or differing p95/p99 sample populations). It intentionally does **not** require arithmetic mean frame time to be below p95 because that relationship is not mathematically guaranteed for heavy-tailed data.

Future canonical adapters should authenticate Mission/Completion policy authority and the complete runtime/accessibility producer batch inside this module before constructing trusted subjects. Simulator evidence is never promoted to a physical-device target by this evaluator.

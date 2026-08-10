# ForgeQualityCore

Pure-Swift V14 quality-budget truth for generated-project completion.

This package evaluates explicit performance/accessibility targets against exact-run measurements. It does **not** measure a device, authenticate runtime/accessibility producers, or complete a mission. Candidate policy/measurement values are Codable for durable transport, while accepted policy, current-run, and producer trust are non-Codable whole-subject bindings with module-internal construction. A persisted or model-shaped receipt cannot mint a passing quality gate by itself.

The quality subject binds current Mission/Completion target plus a host-authenticated current run carrying exact project/source/checkpoint/runtime/host-build/run/environment/device/OS identity. Targets encode metric direction, minimum sample counts, run/journey scope, and optional exact environment requirements. Missing/undersampled/environment-mismatched evidence blocks; a known threshold violation fails even when another target is missing.

Future canonical adapters should authenticate Mission/Completion policy authority and runtime/accessibility producer evidence inside this module before constructing trusted subjects. Simulator evidence is never promoted to a physical-device target by this evaluator.

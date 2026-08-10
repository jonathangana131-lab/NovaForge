# ForgePerformanceCore

`ForgePerformanceCore` is NovaForge's machine-readable generated-runtime performance acceptance truth layer.

It does **not** measure a project itself and it does not claim any iPhone, Simulator, FPS, memory, thermal, latency, or energy result. It evaluates a validated performance budget against a validated measurement batch only after host-authenticated trust has been bound to the complete budget and complete batch subjects.

## Trust boundary

Persisted/model-authored receipt IDs are candidate metadata, not authority. `ForgePerformanceBudgetTrustBinding` and `ForgePerformanceMeasurementTrustBinding` are non-Codable and have module-internal initializers. Reusing a trusted receipt ID with modified thresholds, target identity, runs, samples, or observation values cannot authorize the altered subject.

A future canonical host/runtime adapter inside this package must mint those bindings only after independently authenticating the producer/budget authority. Until that exists, external code cannot manufacture accepted performance evidence.

## Acceptance semantics

- target identity binds project, source revision, mission, runtime/revision, physical-vs-Simulator environment, exact hardware identifier, OS version/build, measurement protocol/revision, budget revision, and budget authority receipt ID;
- all required runs must be present;
- every accepted run must contain every constrained metric with enough samples;
- the worst observed value across the complete trusted run set is evaluated, so a bad run cannot be averaged away;
- missing/incomplete evidence blocks; over-budget evidence fails; only complete in-budget evidence accepts;
- derived evaluation is non-Codable; relaunch must re-evaluate archived raw inputs with fresh host trust.

## V14 truth boundary

Simulator evidence cannot satisfy a physical-device target because environment identity is part of the exact target. No research-paper result or other-device measurement becomes iPhone 12 proof. A model saying `fast`, `passed`, or `done` is never performance evidence.

The intended integration path is:

`canonical runtime/device producer -> authenticated whole-subject trust binding -> ForgePerformanceEvaluator -> Completion/Repair/History adapter`

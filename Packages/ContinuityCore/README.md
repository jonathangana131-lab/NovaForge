# ContinuityCore

Pure-Swift V14 continuity truth for NovaForge long missions.

This package models checkpoint-bound execution leases, foreground/system/verified remote handoff, stale-result rejection, relaunch-safe persistence, truthful Live Activity/notification projection, and resumable background-transfer state.

## Trust boundary

- Execution requires a fresh, non-Codable `ContinuityExecutionGrant` minted only by a canonical host adapter inside this module after real environment authorization.
- Mission authority is fresh, non-Codable, and **purpose-bound**: checkpoint advance authority cannot be replayed as state/completion projection authority.
- Public `ContinuitySnapshot` construction starts at neutral `.ready` with epoch zero; live state and replay-protection epochs are reducer/authority outputs.
- Live `ContinuitySnapshot` and `ContinuityWorkLease` are intentionally non-Codable.
- `ContinuityArchive` never serializes an active lease. Archiving an executing snapshot records it as `suspended(.executionEnvironmentLost)`, so relaunch cannot claim work is still running without reacquiring authority.
- Mission-owned `needsDecision`, `blocked`, and `completed` projections are not durable Continuity authority: archiving them records `suspended(.missionStateRevalidationRequired)`, and forged persisted terminal projections are rejected on decode.
- `missionStateRevalidationRequired` cannot resume on execution authority alone. Canonical Mission must explicitly reproject `.ready`, `.needsDecision`, `.blocked`, or `.completed` first.
- Advancing to a newer Mission revision cannot carry an older Mission-owned completion/decision/block projection forward without revalidation.
- Background transfer archives revalidate nested invariants on decode and are bounded.

This package does **not** implement or claim ActivityKit delivery, BackgroundTasks/continued-processing eligibility, background URLSession wiring, a cloud backend, Mac pairing, indefinite iPhone background execution, Simulator/device endurance, or physical-device proof. Platform adapters remain a later closure rung.

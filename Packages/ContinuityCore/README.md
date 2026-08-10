# ContinuityCore

Pure-Swift V14 continuity truth for NovaForge long missions.

This package models checkpoint-bound execution leases, foreground/system/verified remote handoff, stale-result rejection, relaunch-safe persistence, truthful Live Activity/notification projection, and resumable background-transfer state.

## Trust boundary

- Execution requires a fresh, non-Codable `ContinuityExecutionGrant` minted only by a canonical host adapter inside this module after real environment authorization. Every execution grant is bound to the exact snapshot generation (`issuedForEpoch`) it authorizes; any epoch advance makes an older grant stale.
- Mission authority is fresh, non-Codable, **purpose-bound**, and generation-bound: checkpoint advance authority cannot be replayed as state/completion projection authority, and any Mission authority issued for an older epoch is invalid after the snapshot advances.
- Public `ContinuitySnapshot` construction starts at neutral `.ready` with epoch zero; live state and replay-protection epochs are reducer/authority outputs.
- Live `ContinuitySnapshot` and `ContinuityWorkLease` are intentionally non-Codable.
- `ContinuityArchive` never serializes an active lease. Archiving an executing snapshot records it as `suspended(.executionEnvironmentLost)`, so relaunch cannot claim work is still running without reacquiring authority.
- Mission-owned `needsDecision`, `blocked`, and `completed` projections are not durable Continuity authority: archiving them records `suspended(.missionStateRevalidationRequired)`, and forged persisted terminal projections are rejected on decode.
- `missionStateRevalidationRequired` cannot resume on execution authority alone. Canonical Mission must explicitly reproject `.ready`, `.needsDecision`, `.blocked`, or `.completed` first.
- An explicit `.userPaused` suspension cannot be overridden by a normal execution grant. Leaving user pause requires a separate fresh, non-Codable `ContinuityUserResumeAuthority` bound to that exact paused epoch; after any epoch advance it is stale, and execution still needs its own fresh generation-bound grant.
- Mission state projection also cannot erase `.userPaused`; user steering must be explicitly resumed before canonical Mission projection may change the continuity run state.
- Advancing to a newer Mission revision cannot carry an older Mission-owned completion/decision/block projection forward without revalidation.
- Same-process capability replay fails closed across system expiration, user pause/resume, environment loss, accepted worker results, checkpoint advance, Mission projection, and handoff because all fresh authority is validated against the current snapshot epoch before mutation.
- Background transfer archives revalidate nested invariants on decode and are bounded.

This package does **not** implement or claim ActivityKit delivery, BackgroundTasks/continued-processing eligibility, background URLSession wiring, a cloud backend, Mac pairing, indefinite iPhone background execution, Simulator/device endurance, or physical-device proof. Platform adapters remain a later closure rung.

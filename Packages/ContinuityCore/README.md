# ContinuityCore

Pure-Swift V14 continuity truth for NovaForge long missions.

This package models checkpoint-bound execution leases, foreground/system/verified remote handoff, stale-result rejection, relaunch-safe persistence, truthful Live Activity/notification projection, and resumable background-transfer state.

## Trust boundary

- Execution requires a fresh, non-Codable `ContinuityExecutionGrant` minted only by a canonical host adapter inside this module after real environment authorization.
- Mission checkpoint/completion projection requires a fresh, non-Codable `ContinuityMissionAuthority` from the canonical Mission adapter.
- Live `ContinuitySnapshot` and `ContinuityWorkLease` are intentionally non-Codable.
- `ContinuityArchive` never serializes an active lease. Archiving an executing snapshot records it as `suspended(.executionEnvironmentLost)`, so relaunch cannot claim work is still running without reacquiring authority.
- Background transfer archives revalidate nested invariants on decode and are bounded.

This package does **not** implement or claim ActivityKit delivery, BackgroundTasks/continued-processing eligibility, background URLSession wiring, a cloud backend, Mac pairing, indefinite iPhone background execution, Simulator/device endurance, or physical-device proof. Platform adapters remain a later closure rung.

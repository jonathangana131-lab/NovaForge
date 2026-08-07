# NovaForge V13 migration inventory

Status: first executable archaeology checkpoint for issue #42  
Protocol: NF-SWARM-v13  
Source inspected: `df1740f12f5e0b26780868c1cd906ee8cae497ae`

This document is intentionally narrower than a rewrite design. It records the durable truth that the NovaForge 2.0 rewrite must preserve before old presentation/state architecture can be retired. The machine-readable authority for this checkpoint is `docs/migration/novaforge-v13-durable-data-contract.json`; `scripts/validate_v13_migration_contract.py` makes the highest-risk invariants fail closed.

## What the live code proves

### 1. SwiftData is durable user state, but it already has a safe migration boundary

`LaunchPersistenceStorePaths` names `Application Support/NovaForge.store` as the primary store and treats the SQLite main/WAL/SHM set as one recovery unit. The launch path already distinguishes:

- ordinary primary open;
- an exact known-legacy pre-explicit schema;
- the explicit V1 schema;
- staged migration to the current schema;
- a durable compatibility fallback; and
- verified non-destructive recovery snapshots.

The pre-explicit store and explicit V1 both advertise version identifier `1.0.0`, so the current implementation correctly does **not** use that identifier alone as migration authority. It checks the released model checksum/hash/entity signature, performs the bounded inferred bridge only for that known legacy preimage, then requires the exact explicit-V1 signature before staged migration continues.

That behavior is foundation worth preserving. NovaForge 2.0 should migrate the data model, not replace it with “create a new empty store and import whatever happens to decode.”

### 2. Compatibility recovery is an authoritative branch until reconciled

The compatibility store lives at `Application Support/CompatibilityRecovery/NovaForge-Compatibility.store`. When its durable active marker exists, a newly-readable primary does not automatically win: the selector keeps serving the compatibility branch because it may contain newer chats, receipts, or project state.

V13 consequence: a rewrite must perform identity-aware reconciliation before retiring compatibility data. “Primary opens” is not evidence that fallback state is obsolete.

### 3. Engine ownership/recovery evidence is separate from SwiftData

`AgentEngineRunIndexStorePaths` owns `Application Support/AgentEngine/v1/run-ownership-index.ledger`. Its path construction rejects escapes/symlinks and applies complete file protection plus backup exclusion.

This is not presentation state. It participates in process-safe accepted-run ownership and recovery. The V13 Mission Engine can supersede its internal format only after run identity, accepted/interrupted/terminal state, and stale-result rejection are proven across migration and relaunch.

### 4. Policy authority and mutation rollback are separate security state

`AgentPolicyStorePaths` owns protected `policy-authority.ledger`, `mutation-effect-lifecycle.ledger`, and the `checkpoints/` directory under `Application Support/AgentPolicy/v1/`.

`POSIXWorkspaceCheckpointStore` publishes immutable content-addressed whole-workspace before-state snapshots. Restore is deliberately idempotent and re-validates workspace containment/identity plus the effect key, operation payload, revision, and before-state digest.

These stores are not caches. Replacing them without an equivalent verified authority/recovery boundary could either grant an operation authority it never had or destroy the rollback evidence required after an interrupted mutation.

### 5. User workspaces are not part of “reset the app database”

The debug persistence reset explicitly leaves user workspaces untouched while removing test engine/policy/SwiftData authority. Workspace checkpointing also resolves actual workspace roots through `AgentWorkspaceRootProviding` rather than assuming the database path owns source files.

V13 consequence: project source/assets are first-class user value. Missing/rebuilt metadata is never permission to delete a workspace.

### 6. Credentials are a preserve-in-place Keychain boundary

`KeychainStore` uses generic-password items under service `com.joey.NovaForge` and writes secret data as `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`.

The rewrite should migrate **references and account semantics**, not secret values. Credentials must never pass through a plaintext JSON migration payload, SwiftData bridge record, Project Brain, History receipt, log, or project export. If an account cannot be mapped safely, the correct fallback is explicit re-authentication.

## Preserve, migrate, replace

| Area | V13 disposition | Why |
| --- | --- | --- |
| Primary SwiftData user/project/history records | Migrate losslessly | User value and accepted history already have durable identity. |
| Compatibility SwiftData branch | Preserve until reconciled | It may be newer than a readable primary. |
| Recovery snapshots | Preserve in place | They are verified preimages/evidence for unresolved migration. |
| AgentEngine ownership ledger | Migrate only with recovery proof | Mission continuity must not duplicate or lose accepted execution. |
| AgentPolicy ledgers | Preserve until equivalent authority is proven | Security/replay truth, not presentation. |
| Workspace checkpoints | Preserve until equivalent rollback proof | Immutable before-state supports idempotent recovery. |
| User workspace files/assets | Preserve in place by default | They are the user's actual creations. |
| Keychain credential values | Preserve in place, never plaintext-migrate | Device-bound secret boundary. |
| Giant views / duplicated presentation state / obsolete navigation | Replace | V13 explicitly authorizes architecture rewrite; internal shape has no user-value claim. |
| Derived projections/caches | Rebuild from source truth where proven derived | A cache must never become the migration authority. |

## Deletion gate for future rewrite PRs

A legacy path is removable only when all applicable checks are true:

1. Its durable-data class appears in the machine-readable contract.
2. A replacement owner is named and has a deterministic migration/reconciliation path.
3. Representative old-store/project fixtures are migrated and reopened after relaunch.
4. User-value identity/lineage and accepted receipts compare as expected.
5. In-flight mutation/recovery fixtures prove no duplicate execution and valid rollback.
6. Security authority is equivalent or stronger; no migration can mint approval.
7. Credentials never leave Keychain plaintext boundaries.
8. The accepted replacement has a durable commit/checkpoint before old data is deleted.
9. Failure at any step leaves the old authoritative data recoverable rather than silently resetting it.

## Validation

Run:

```sh
python3 scripts/validate_v13_migration_contract.py --self-test
```

The validator currently guards the released legacy entity signatures, exact source-commit pinning, required durable-store inventory, no-discard rules for protected data, compatibility-store reconciliation, protected ledger locations, and the Keychain no-plaintext/no-export boundary. Its built-in adversarial cases prove those checks reject representative unsafe edits.

## Next controlled seam

This checkpoint deliberately does **not** mutate `AgentPadApp`, provider runtime, Mission Engine, or UI code. The next #42 implementation should consume this contract in a migration fixture harness that opens representative released stores/workspaces, projects the new V13 ownership model, relaunches, and compares identity/lineage/evidence before any broad deletion of legacy presentation/state code.

# V14 Forge Compact model-artifact cache identity handoff

Worker: `GPT56-NF-V14-FC-ARTIFACT-8A8G`  
Canonical base: `main@5cd5a75849fde2a0d16d5c915433364e7d8e8a60` (merged #112)  
Clean implementation branch: `worker/GPT56-NF-V14-FC-ARTIFACT-8A8G/forgecompact-artifact-identity/e1`  
Clean implementation head: `0583f99ab6c0cac103a9a1c1f1c7d368a75fd35e`

## Finding

Merged #112's `ForgeCompactCacheIdentity` bound friendly model/revision/weight-profile identifiers but did not bind immutable model artifact bytes. If a catalog/runtime reused those identifiers for replaced, corrupt, or different GGUF bytes, exact cache-identity equality could still authorize future prefix/KV reuse across different weights.

## Implemented hardening

The clean implementation branch changes exactly two product files:

1. `Packages/ForgeCompactCore/Sources/ForgeCompactCore/ForgeCompactCacheIdentity.swift`
   - adds required `modelArtifactSHA256`;
   - requires canonical lowercase 64-hex SHA-256 at construction;
   - decode re-enters the same validation;
   - strict identity equality therefore rejects reuse when model bytes differ.

2. `Packages/ForgeCompactCore/Tests/ForgeCompactCoreTests/ForgeCompactCapsuleIntegrationTests.swift`
   - same friendly IDs + different artifact digest cannot reuse prefix/KV;
   - malformed artifact digest fails construction;
   - tampered decoded artifact digest fails validation.

Final compare from #112 base to clean head: 0 behind; net source delta +10/-6 and tests +10/-0. Temporary validation workflows were added only to collect evidence and then removed; the final implementation tree contains no workflow changes.

## Verification

Isolated Swift 6.2.1 exact-semantics harness:
- debug with warnings-as-errors: 4/4 PASS;
- release with warnings-as-errors: 4/4 PASS.

Full checked-in `Packages/ForgeCompactCore` GitHub Actions validation used temporary Linux gate run `31256370553` on product bytes that remain unchanged in the clean final head:
- debug job: SUCCESS;
- release job: SUCCESS;
- `git diff --check`: PASS;
- warnings-as-errors: enabled.

macOS validation was queued behind saturated runners and is not claimed. No physical-device, model-compatibility, actual KV-reuse, RAM, thermal, speed, or iPhone performance result is claimed.

## Landing status

Intended PR title: `[V14] Bind Forge Compact KV reuse to model artifact bytes`.

GitHub REST content creation is temporarily blocked by a secondary rate limit for this account, so multiple spaced PR-creation attempts were rejected even though branch/file writes and read APIs remain healthy. No PR exists for this branch at handoff time.

When content creation is available again:
1. fresh-check main and collision search;
2. if still based cleanly on canonical Forge Compact, open a draft PR from the clean implementation branch (not this handoff branch);
3. run the repository's canonical package gate once #118 or its successor is current-main authoritative;
4. independent review, then land with expected-head protection.

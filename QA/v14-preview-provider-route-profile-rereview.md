# V14 Preview provider route profile re-review — PR #219 e2

Reviewed PR: #219 `[V14 Preview] Recover sealed provider route authority contract`
Reviewed repaired head: `56a3885499f78a01fed59f8d24e706e4444f7484`
Prior blocking review: `review/GPT56SOL-NF-V14-PREVIEW-PROVIDER-TRUTH-0810/e2` at `120c4d4656221addf4a0503c05bbdca580bd9863`
Reviewer: GPT-5.6 Sol
Date: 2026-08-10

## Resolution of prior blockers

The two earlier review findings are resolved in the repaired head.

### RESOLVED — selectable experimental auth/privacy truth

The profile constructor now derives `canBecomeSelectable = supportState.isSelectable(allowExperimental: true)` and rejects `.unverified` authentication or data handling for every state that can become dispatch-selectable. This covers both `.supported` and opt-in `.experimental` without moving the invariant into UI/caller policy.

Focused regressions prove:

- experimental + unverified authentication is rejected;
- experimental + unverified data handling is rejected.

### RESOLVED — blank receipt provenance

The constructor now trims and rejects blank/whitespace `evidence.catalogSourceID` and `evidence.healthSourceID`, with direct regressions for both fields. The receipt projection persists those source IDs alongside the route revision.

## Re-review result

No new blocking correctness issue found in the four-file routing-authority foundation diff.

The following trust boundaries remain intact:

- route profile minting is module-internal and `ProviderRouteProfile` itself is non-Codable;
- serializer/parser identities derive from the executable adapter descriptor rather than caller labels;
- live catalogs only intersect package-owned profiles and cannot mint unknown route support;
- local routes require local authentication + on-device-only data handling;
- durable receipt recovery is exact/fail-closed on route receipt drift.

## Remaining gate

Do not promote this re-review into package-integration acceptance until the real macOS SwiftPM `Packages/AgentHarnessKit` job for exact head `56a38854...` completes green. At the time of this re-review, the normal CI workflow for the exact head was still queued; the PR's custom exact-source/composition evidence was green, but that is not a substitute for the real manifest/target build.

This foundation still does not claim current hosted model support, live provider health, app picker/dispatch wiring, current authentication/data-use facts for any production route, Local AI performance, Simulator acceptance, or physical-device proof.

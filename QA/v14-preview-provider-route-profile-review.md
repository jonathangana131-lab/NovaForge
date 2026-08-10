# V14 Preview provider route profile review

Reviewed branch: `worker/GPT56-SOL-NF-V14-PREVIEW-ROUTE-0810/provider-route-profile/e1`
Reviewed head: `654bba727b387015eff0c3554cc946688a8e69cd`
Reviewer lane: `review/GPT56SOL-NF-V14-PREVIEW-PROVIDER-TRUTH-0810/e1`
Date: 2026-08-10

## P1 — selectable experimental routes can retain unverified auth/privacy truth

`ProviderProductSupportState.isSelectable(allowExperimental:)` returns `true` for `.experimental` when the caller opts in. `ProviderRouteProfile.init` only rejects `.unverified` authentication and `.unverified` data handling when `supportState == .supported`.

That means this profile is currently constructible inside package authority and dispatch-selectable when experimental opt-in is enabled:

- `supportState = .experimental`
- `authenticationMode = .unverified`
- `dataHandling.classification = .unverified`
- `isSelectable(allowExperimental: true) == true`

For the Preview truth boundary, experimental should mean the model/route is experimental, not that NovaForge may dispatch before it knows the route's authentication and data-handling contract. A route that can actually be selected should have bounded auth/privacy truth, with any material disclosure enforced separately.

Recommended repair:

1. Change the constructor invariant from `supportState == .supported` to all selectable support states (`.supported` and `.experimental`) for auth/data-handling verification.
2. Add adversarial tests proving `.experimental + .unverified auth` and `.experimental + .unverified dataHandling` are rejected even though experimental opt-in can make the support state selectable.
3. Keep `.legacy`, `.broken`, `.unverified`, and `.removedDoNotOffer` non-selectable as already implemented.

Do not weaken the fix by merely changing `allowExperimental` UI copy; the trust invariant belongs at profile construction/authority.

## P2 — route evidence source IDs may be empty

The constructor rejects an empty `evidence.revision`, but does not reject empty `catalogSourceID` or `healthSourceID`. Both are persisted into `ProviderRouteReceiptProjection`, so a `.supported` route can currently carry an apparently revisioned receipt with missing catalog/health provenance.

Recommended repair:

- add `emptyCatalogSourceID` and `emptyHealthSourceID` validation failures (or equivalent),
- reject whitespace-only values,
- add focused tests for both fields.

## Scope / non-findings

The registry's unknown-live-model behavior is correctly fail-closed: live catalogs intersect curated profiles rather than minting new route authority. The internal-only `ProviderRouteProfile` initializer plus the static external-consumer probe is also directionally correct.

This review does not claim the branch is integrated into app selection/dispatch; its compare against current Preview main shows the branch currently adds the profile domain + tests only. Integration and exact provider health evidence remain separate closure work.

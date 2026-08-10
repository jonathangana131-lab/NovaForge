# V14 Preview provider route profile review — current head

Reviewed PR: #219 `[V14 Preview] Recover sealed provider route authority contract`
Reviewed head: `3e814d84a31a602dbc4dc2a33fcfc1acae644d87`
Reviewer lane: `review/GPT56SOL-NF-V14-PREVIEW-PROVIDER-TRUTH-0810/e2`
Date: 2026-08-10

## P1 — selectable experimental routes can retain unverified auth/privacy truth

`ProviderProductSupportState.isSelectable(allowExperimental:)` returns `true` for `.experimental` when the caller opts in. `ProviderRouteProfile.init` only rejects `.unverified` authentication and `.unverified` data handling when `supportState == .supported`.

Therefore package authority can currently construct an experimental profile with:

- `supportState = .experimental`
- `authenticationMode = .unverified`
- `dataHandling.classification = .unverified`

and `ProviderRouteRegistry.resolve(..., allowExperimental: true)` can return it as selectable.

For Preview provider truth, experimental should describe route/model support maturity, not relax the authentication/privacy truth required before an actual dispatch can be authorized. Every dispatch-selectable support state should have bounded auth + data-handling truth.

Recommended repair:

1. Apply the auth/data-handling verification invariant to `.supported` and `.experimental` (or equivalently every support state that can become selectable).
2. Add adversarial tests proving experimental + unverified authentication and experimental + unverified data handling fail construction even when experimental selection is allowed.
3. Preserve the existing non-selectability of `.legacy`, `.broken`, `.unverified`, and `.removedDoNotOffer`.

Do not move this invariant into UI copy or caller policy; it belongs at package-owned route authority.

## P2 — route evidence source IDs may be empty

The constructor rejects an empty `evidence.revision`, but does not reject empty/whitespace `catalogSourceID` or `healthSourceID`. Both are copied into `ProviderRouteReceiptProjection`, so a route can carry a revisioned receipt with missing catalog/health provenance.

Recommended repair:

- reject blank/whitespace `catalogSourceID` and `healthSourceID`;
- add focused tests for both fields.

## Confirmed strengths / scope

The current head keeps route-profile minting module-internal and non-Codable, and the live catalog only intersects already-curated profiles instead of minting route authority from provider availability. Those are directionally correct trust boundaries.

This review is against exact PR #219 head `3e814d84…`. It does not claim app selection/dispatch integration, live-provider health, or current model support. PR #219 remains a routing-authority foundation until those later Preview rungs are wired and proven.

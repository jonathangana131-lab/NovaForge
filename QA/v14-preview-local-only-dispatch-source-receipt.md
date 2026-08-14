# V14 Preview Local Only Dispatch Source Receipt

Protocol: NF-SWARM-v14  
Worker: GPT56SOL-PREVIEW-LOCALONLY-SOURCE-GUARD-20260810-1831  
Base: `main@991ece0ed9add9acf1108055f489b25f6cc9843f`  
Branch: `agent/v14-preview-local-only-dispatch-source-guard`

## Preview release question

For the normal Preview agent harness, a route accepted as `.builtInLocalModel` must not silently acquire hosted credentials or fall through to a hosted provider transport.

This lane adds a deterministic source-level regression guard around the production composition seam. It is intentionally independent of the existing Local Model catalog/runtime work and the separate dynamic Local-Only network-audit candidate.

## Exact source evidence on the claimed base

The guard requires all of these facts to stay true together:

- `AgentSystemProductionComposition` resolves the `.builtInLocalModel` environment with both hosted credential and hosted account ID set to `nil`.
- the `.builtInLocalModel` provider composition reconstructs `.localSingleCallTools(modelID: route.modelID)`, verifies the declared route still equals the accepted route, and calls the local gateway factory.
- the production `localSingleCallTools(selection:workspace:)` factory constructs `AgentLocalModelProviderTransport` using `LocalModelClient.shared` and the local tools authority.
- the sealed local gateway helper accepts `LocalToolsAuthority` plus `AgentLocalModelProviderTransport`, verifies lane and descriptor equality, and binds that exact local descriptor/transport into `AgentProviderTransportRouter`.
- `AgentProviderTransportRouter` requires an exact adapter-ID binding and exact descriptor equality before dispatching; the guard rejects source-level first/default fallback patterns in that router.
- `AgentLocalModelProviderTransport.swift` contains the typed `AgentLocalModelInferenceStreaming` seam and no `AgentHostedProviderTransport`, `URLSession`, `URLRequest`, hosted API host, or OpenAI client marker.

## Durable regression added

- `scripts/verify_v14_preview_local_only_dispatch_contract.py`
- `.github/workflows/v14-preview-local-only-dispatch-contract.yml`

The workflow runs on pull requests that touch any guarded production dispatch file or the verifier itself, on matching pushes to `main`, and by manual dispatch.

## Authoring validation

The Python verifier draft was syntax-compiled with `python3 -m py_compile` before publication: PASS.

The branch-level GitHub Actions result must be treated as the authoritative exact-tree run once the pull request exists. This receipt must not claim CI success before that run is observed.

## Non-claims / remaining release proof

This is **source-composition evidence only**. It does not prove that a physical iPhone emitted zero network packets, does not replace dynamic URL/session interception, and does not qualify model RAM, thermal behavior, speed, or iPhone 12 compatibility.

A complete Local Only release claim still needs runtime/device evidence appropriate to the candidate. The older `LocalOnlyNetworkAuditCore` candidate lane remains separate authority; this worker did not modify or supersede it.

No production Swift behavior changed in this lane.

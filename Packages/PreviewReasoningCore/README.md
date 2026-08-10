# PreviewReasoningCore

`PreviewReasoningCore` defines the NovaForge Preview's canonical product-level reasoning contract.

Public scale:

`Low -> Medium -> High -> Extra High -> Ultra`

## Ultra contract

`Ultra` is the single strongest public Preview level. Its derived profile requests:

- isolated parallel review orchestration;
- maximum-useful context retrieval;
- strictest verification;
- two verifier passes;
- maximum available qualified reasoning effort;
- isolated workspaces.

These are relative execution requirements, not claims about provider support, tokens, RAM, latency, thermal behavior, or device performance. Runtime adapters must still use qualified capabilities and fail closed when a requirement cannot be satisfied.

## Legacy convergence

The old app contains two orchestration spellings, `ultra` and `ultraCode`. Both map to canonical `Ultra` here so a saved strongest-mode choice is never silently weakened. Legacy standard reasoning effort remains mapped only across Low through Extra High.

Persist the canonical `PreviewReasoningLevel`, not the derived `PreviewReasoningProfile`. The profile is intentionally non-Codable and must be derived from the canonical level at execution time.

## Current integration handoff

At branch creation, live main was `fd9edf6da45571d70d45ca1e9b70a86c8797ac04`.

Current app integration points observed on that head:

1. `AgentPad/Views/ChatComposer.swift`
   - fifth public stop is still named `UltraCode`;
   - legacy `.ultra` is currently presented/migrated as Extra High.
2. `AgentPad/Services/AIProvider.swift`
   - `AgentRunPreferenceStore` currently migrates persisted `.ultra` to `.xhigh + .standard`;
   - this path overlaps active provider PR #12 and was intentionally not edited in this lane.
3. `AgentPad/Services/AgentSystemFreshRunRequestFactory.swift`
   - `.ultraCode` already binds concrete strongest-mode feature gates: `v2UltraCodeOrchestration` and `v2IsolatedAgentWorkspaces`;
   - this is the natural runtime adapter seam after the product contract is accepted.

Integration acceptance should prove the visible fifth stop says `Ultra`, legacy strongest-mode persistence remains strongest, and the resulting fresh-run request carries the strongest supported effort plus the required orchestration/workspace features. Capability shortfalls must be surfaced rather than silently falling back while still labeling the run Ultra.

## Validation

Exact corrected package bytes were tested locally with Swift 6.2.1 on `x86_64-unknown-linux-gnu`:

- `swift test -Xswiftc -warnings-as-errors`: 6/6 passed;
- `swift test -c release -Xswiftc -warnings-as-errors`: 6/6 passed.

The repository's current `scripts/codex-test.sh` runs `Packages/AgentHarnessKit` only, so generic repository Critical CI must not be misreported as direct execution evidence for this package until the independent dynamic-package gate lands or this package is explicitly added to an accepted repository test path.

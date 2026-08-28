# NovaForge Local AI 2.0 migration

## Deployment and compatibility decision

The integrated project remains simulator-buildable on the available Xcode 26 toolchain and targets iOS 26. The app does not unconditionally link Apple’s iOS-27-only `coreai-models` package into that target. Core AI descriptors fail closed when the iOS 27 runtime, Xcode 27 package modules, supported physical hardware, tokenizer resources, or a pinned AOT asset are absent.

This is a compatibility decision, not evidence that Core AI runs. The current Intel Mac cannot perform the required Xcode 27 export/device lane, the iPhone 12 (`iPhone13,2`) is not admitted for Core AI, and no Core AI-vs-llama result exists. The separate Xcode 27 workflow is generic-build/export preparation only; it cannot substitute for a physical receipt.

## Catalog and corpus pins

`AgentPad/Resources/LocalModelCatalog.v2.json` is the versioned manifest. It records immutable revisions, exact download size and SHA-256 for downloadable GGUFs, licenses, source URLs, templates, limits, memory admission, engine/location, compression, and physical benchmark status. Its current SHA-256 is `79312032128c195cf8131970a4760f281ecbf9557aa3615c8aa0e6f213ae313d`.

`AgentPad/Resources/LocalAI2Corpus.v1.json` contains 19 deterministic Swift, repository-grounding, constrained-tool, refusal, instruction-following, continuity, repetition/garbage, throughput, and cancellation cases. The app and test fixture copies are byte-identical and pinned to `75fd1e718c227ee71f350c336522074a0dc66d56b144a1eed028c79cc35519e4`.

`scripts/validate-local-ai-catalog.sh` checks both exact digests and semantic safety invariants. `scripts/verify-local-ai-source-pins.sh` separately audits immutable upstream API metadata without downloading multi-gigabyte model artifacts.

Persisted model IDs migrate as follows:

| Old ID | Local AI 2.0 ID |
| --- | --- |
| `Siddh07ETH/Atlas-Coder-2-0.5B-Q4_K_M` | `LiquidAI/LFM2.5-350M-QAD-Q4_0` |
| `Qwen/Qwen2.5-Coder-1.5B-Instruct-Q2_K` | `Qwen/Qwen2.5-Coder-1.5B-Instruct-Q3_K_M` |

Receipt migration may change only the model ID. It must preserve the originally recorded immutable revision and model hash because an old receipt cannot prove provenance for a replacement artifact.

## Delivery and rollback

Downloadable entries use revision-pinned HTTPS URLs, expected byte counts, and SHA-256 verification. Resume may append only after a valid partial response; a same-size corrupt artifact is invalidated and restarted rather than treated as complete. Catalog-owned partial/final files may be recovered without deleting unrelated user data.

The pinned Qwen2.5-Coder 1.5B Q4 route remains the configured rollback default. LFM2.5 1.2B is a candidate only. LFM2.5 2.6B is blocked on the 4 GB iPhone 12. DSpark remains disabled because the vendored in-process Swift/C API has no compatible target/draft control surface.

`scripts/prepare-llama-hybrid-xcframework.sh` pins the modern physical-device archive (`b10630`) and the Intel-compatible simulator slice (`b6102`) by archive checksum before assembly. The split must remain visible in runtime receipts.

## Companion privacy

Qwen3.8-27B has two explicit Power routes. `Power — On-device streamed (experimental)` offers separately pinned IQ1_S, IQ2_XXS, and Q3_K_M text-only candidates, layer-range read-ahead/page eviction, a 1.5 GB stage-window target, Q8 KV under pressure, and one generation lease; each remains unadmitted until its exact iPhone 12 physical matrix passes. `Power — Companion` requires an explicitly configured private-LAN endpoint, content-sharing consent, and exact model/revision attestation before any prompt is sent. Public hosts, credential-bearing URLs, query strings, fragments, and unsafe redirects fail closed. NovaForge never silently changes Local execution into LAN or Cloud execution.

## Core AI preparation

On an Apple-silicon Xcode 27 host, `scripts/export-coreai-qwen.sh` checks out apple/coreai-models at `f43b6da728c6af5af15db345ffb2d8402d27013b`, exports Qwen3 0.6B at a fixed 1,024-token context, invokes `coreai-build`, and prints generated hashes. Output is not copied into the app automatically: model assets, tokenizer resources, metadata, licenses, architecture support, and catalog checksums must be reviewed and pinned together.

Removing an unproven candidate does not remove the Qwen rollback. A failed admission, artifact verification, route attestation, or structured decision fails closed and never silently changes execution location.

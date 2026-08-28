# NovaForge Local AI 2.0 benchmark report

Report date: 2026-08-27

## Claim policy

This report records only evidence reproduced from the current integration worktree. A generic build proves compilation only, simulator evidence stays simulator-only, and a physical or Core AI claim requires a matching receipt bound to the exact device, app, model, source, and corpus hashes. Earlier task notes referenced simulator receipts that are not present in this worktree, so their timing and pass-count claims are not repeated here.

## Observed evidence

| Check | Observed result |
| --- | --- |
| Development host | Intel (`x86_64`) Mac, macOS 15.7.4 (24G517), 40 GB RAM |
| Selected toolchain | Xcode 26.1.1 (17B100) |
| Catalog validation | Passed; 10 exact entries, SHA-256 `d46f4fdeebe03bf4da13ecfaeacd8da8b9ce02c91a8b710bb799a5abdc817e24` |
| Evaluation corpus validation | Passed; 19 cases, SHA-256 `75fd1e718c227ee71f350c336522074a0dc66d56b144a1eed028c79cc35519e4` |
| Immutable upstream audit | Passed for the original five GGUF artifacts plus exact Qwen3.8 IQ1_S, IQ2_XXS, and Q3_K_M candidates at `f4480441d4fb4fe2e283c5d1e05d230195afd939`, base revision `1d4bf0f2ff6012fd82039f2fa52739d0dd7c60c0`, and apple/coreai-models revision `f43b6da728c6af5af15db345ffb2d8402d27013b` |
| Full simulator build | Passed for Debug / `iphonesimulator`, including both simulator architectures; `** BUILD SUCCEEDED **` |
| Focused Local AI/runtime suite | Passed on the iPhone 12 / iOS 26.1 simulator; 117 tests, 0 failures |
| Simulator smoke | Passed with `BUILD_FIRST=1`; build, install, launch, and Forge screenshot completed |
| Simulator tour | Local Xcode 26 captured 20 distinct routes and the corrected semantic verifier passed them in a diagnostic replay. The definitive Xcode 27 build/test/smoke/tour/OCR package is delegated to `.github/workflows/local-ai-xcode27.yml`; no cloud result is claimed until that run completes. |
| Release optimization check | The Intel host did not finish the Release compile inside the 900-second build cap; the process tree was drained. No Release-build claim is made. |
| Physical iPhone 12 | CoreDevice remembers `A9CFDD8D-E5B9-5B93-917A-513357EAD81E` (`iPhone13,2`) but reported it unavailable |
| Physical protocol | Not run because the iPhone was unavailable; no physical throughput, memory, thermal, battery, lifecycle, or quality result is claimed |
| Core AI | Not built or run; Xcode 27, an Apple-silicon export host, pinned AOT assets, and supported physical hardware were unavailable |
| Qwen3.8-27B on iPhone 12 | `On-device streamed (experimental)` implemented with GGUF block planning, read-ahead/page eviction, 1.5 GB stage-window target, storage microbenchmarking, and CPU/partial/full-Metal physical protocol. Performance/admission is unverified until the phone is connected. Companion remains separate and consent-gated. |

Commands observed in this worktree:

```sh
scripts/validate-local-ai-catalog.sh
scripts/verify-local-ai-source-pins.sh
xcodebuild -project AgentPad.xcodeproj -scheme AgentPad -configuration Debug -sdk iphonesimulator CODE_SIGNING_ALLOWED=NO build
xcodebuild -project AgentPad.xcodeproj -scheme AgentPad -configuration Debug -sdk iphonesimulator CODE_SIGNING_ALLOWED=NO -destination id=1CBA4401-4EB3-452A-96EC-63A08422B044 test -only-testing:AgentPadTests/AgentRuntimeLifecycleTests -only-testing:AgentPadTests/AgentLocalModelProviderTransportTests -only-testing:AgentPadTests/CompanionEndpointPolicyTests -only-testing:AgentPadTests/CompanionHostileEndpointTests
BUILD_FIRST=1 SIMULATOR_ID=1CBA4401-4EB3-452A-96EC-63A08422B044 CONFIGURATION=Debug scripts/codex-sim-smoke.sh --reset-ui --open-chat
BUILD_FIRST=1 SIMULATOR_ID=1CBA4401-4EB3-452A-96EC-63A08422B044 CONFIGURATION=Debug scripts/codex-sim-tour.sh
xcrun devicectl list devices
```

The definitive tour evidence is written to `/tmp/novaforge-validation/tour-final-screenshots/tour-verification-summary.txt`. Acceptance requires a `semantic ok` record for every one of the 20 named screenshots in addition to provenance, fixture, size, and uniqueness checks. The verifier specifically rejects empty History and Workspace fixtures, unsettled model readiness, wrong theme destinations, and an unseeded project-intake sheet. These are simulator results only: they do not imply local-model throughput, memory, thermal, battery, lifecycle, or Core AI behavior on a physical phone.

The first-run download card identifies Qwen2.5-Coder 1.5B Q4_K_M as the 1.12 GB Fast fallback default, labels it on-device for iPhone 12, and keeps unbenchmarked LFM candidates separate. The composer and Control model selection use the same catalog default identifier; the LFM 350M candidate is not presented as the installed default.

## Model disposition

| Tier | Model | Current disposition |
| --- | --- | --- |
| Instant | LFM2.5 350M QAD Q4_0 | Pinned candidate; physical iPhone evaluation pending; not trusted with tools yet |
| Fast | LFM2.5 1.2B Instruct QAD Q4_0 | Preferred candidate; not the default without comparative physical evidence |
| Fast | Qwen2.5-Coder 1.5B Q4_K_M | Configured rollback default and preserved functioning route; not newly re-benchmarked on a physical phone in this run |
| Fast | Qwen2.5-Coder 1.5B Q3_K_M | Preserved low-memory rollback |
| Balanced | LFM2.5 2.6B QAD Q4_0 | Rejected by iPhone 12 memory admission; 6 GB minimum catalog requirement |
| Instant/Core AI | Qwen3 0.6B recipe | Export-required and unavailable in the Xcode 26 build; no Core AI result |
| Power | Qwen3.8-27B UD-IQ1_S / UD-IQ2_XXS / Q3_K_M | Three separately pinned experimental on-device streamed candidates; no speed or admission claim before each candidate's A14 physical receipt |
| Power | Qwen3.8-27B | Separate explicit private-LAN companion; never a silent fallback |

No candidate replaces Qwen2.5 until a physical comparison satisfies load, 128-useful-token, lifecycle, footprint, thermal, battery, cancellation, and corpus-quality gates. Core AI has not been compared with llama.cpp.

## Receipt and physical protocol

The required evidence shape is defined in `Docs/LocalAI2-Receipt-Schema.md`. Current in-app timing and evaluation writers are legacy formats; unsupported measurements must remain null and may not be relabeled as measured values.

When the iPhone is truly available, select side-by-side Xcode 27 and run `scripts/run-local-ai-device-protocol.sh` plus three bounded Power runs using `POWER_VARIANT=iq1`, `POWER_VARIANT=iq2`, and `POWER_VARIANT=q3` with `scripts/run-qwen38-out-of-core-device-protocol.sh`. Each run has a hard 45-minute outer budget and fails clearly if Xcode 27/iOS 27 device support is absent. The Power protocol verifies the selected exact artifact, measures internal storage, attempts CPU/partial/full Metal with exact canonical token events, requires positive TTFT and 128 useful tokens, captures staged read/eviction telemetry and process footprint, and rejects unsafe thermal or lifecycle evidence. A security-scoped Control surface separately measures a connected SSD when the user selects the exact artifact.

Until that physical matrix succeeds, `Power — On-device streamed` remains experimental with no performance claim, Companion remains a separate opt-in LAN route, LFM candidates remain pending, and Core AI remains unavailable/unverified. File size greater than DRAM is not treated as proof of impossibility; the open question is measured A14 speed and stability. See `Docs/Qwen38-OutOfCore-Applicability.md`.

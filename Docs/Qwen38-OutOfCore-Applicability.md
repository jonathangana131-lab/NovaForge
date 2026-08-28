# Qwen3.8-27B out-of-core applicability decision

Decision date: 2026-08-27

## Model and artifact under test

NovaForge's Power research lane uses the language-model-only portion of the dense Qwen3.8-27B checkpoint, not its vision projector. The base is pinned to `Qwen/Qwen3.8-27B@1d4bf0f2ff6012fd82039f2fa52739d0dd7c60c0` under Apache-2.0. Three text-only artifacts at `unsloth/Qwen3.8-27B-GGUF@f4480441d4fb4fe2e283c5d1e05d230195afd939` form the physical comparison:

| Candidate | Exact bytes | SHA-256 | Purpose |
| --- | ---: | --- | --- |
| `Qwen3.8-27B-UD-IQ1_S.gguf` | 6,192,222,304 | `ffcaee8ef32a3fc91ac1b57f529f14e3054624c40cfae809437d490aa2cd597d` | Minimum-size trustworthy baseline |
| `Qwen3.8-27B-UD-IQ2_XXS.gguf` | 9,010,048,064 | `8d1b37297d6cf98303cd396896f35e01089ddcc904053a9c6997f7a1c35b8524` | Low-bit quality/dequantization comparison |
| `Qwen3.8-27B-Q3_K_M.gguf` | 13,818,690,528 | `7f3b845b563888ec3abc269474cf744bf703a7ce8766dbb7f696c63975facfd7` | Quality-preserving baseline |

The immutable machine-readable binding is `scripts/out-of-core/qwen3.8-27b-candidates.manifest.json`. The separate `mmproj` artifact is never downloaded or loaded.

The pinned Qwen configuration describes a dense 64-layer text decoder with a repeating three-Gated-DeltaNet/one-full-attention pattern, SiLU-gated feed-forward layers, four KV heads in full-attention layers, and one native MTP layer. This is not a ReLU-sparse TurboSparse Mixtral model. Every optimization below is judged against that actual architecture.

## What applies without changing the model

- Dense layer/stage streaming applies: execute a transformer block, release its weight pages, and fetch the next block. The CMU MLC-LLM prototype establishes that compiler-inserted stage boundaries can run Qwen-family models larger than iPhone memory, though its reported multi-second-per-token results are not NovaForge measurements and its code is not an upstream packaged feature.
- Large sequential reads, deterministic tensor ordering, read-ahead, double-stage windowing, and explicit eviction apply to dense weights. NovaForge parses the pinned GGUF tensor table into exact block ranges, forces file-backed mmap mode, uses llama.cpp per-node compute callbacks as block boundaries, advises the next ranges with `MADV_WILLNEED`, and releases completed ranges with `MADV_DONTNEED`. The target stage-window budget is 1.5 GB. This is stronger than passive mmap, but the operating system still controls the final resident set; only physical `phys_footprint` evidence can prove the bound.
- A minimal fixed 512-token context, 16-token prefill batch, Q8 KV in reduced-memory mode, one process-wide generation lease, CPU/partial-Metal/full-Metal profiles, cancellation, and unload on background/memory/thermal pressure apply unchanged.
- Storage bandwidth and cache behavior must be measured rather than inferred. The app benchmarks deterministic 1 MB sequential reads, 64 KB random reads, an `F_NOCACHE` first pass, a cached repeat, process footprint, and thermal state for both its internal container and an explicitly selected security-scoped external file.

## What requires a derived model or unavailable runtime

- Apple's *LLM in a Flash* windowing and row/column bundling depend on exploitable activation sparsity and a storage-oriented layout. The I/O concepts apply, but its sparse-neuron selection cannot be assumed for Qwen3.8's SiLU/Gated-DeltaNet decoder.
- ActiveFlow targets modern non-ReLU models, but its contextual-sparsity predictor and sparsity-aware self-distillation change execution and training. Adopting it requires reproducible training/conversion code, evaluation against the base checkpoint, and a new immutable derived-artifact ID/checksum. NovaForge does not relabel such an artifact as the official checkpoint.
- PowerInfer-2's 47B result used activation-sparse TurboSparse Mixtral, neuron-cluster scheduling, and Qualcomm Android NPU APIs on 16/24 GB phones. Its cache/pipeline design is informative; its throughput is not transferable to an A14 iPhone with 4 GB, and its NPU path cannot be cargo-culted into Core AI or Metal.
- AirLLM demonstrates dense layer-by-layer loading, but it is a Python/PyTorch runtime rather than a production iOS engine and does not currently establish Qwen3.8/Gated-DeltaNet compatibility.
- The public MLC-LLM iOS runtime supports compiled model packages, but current upstream Qwen3.5/Gated-DeltaNet support is still tracked as work in progress and the CMU stage-boundary pass is not an available upstream component. NovaForge therefore does not claim an MLC Qwen3.8 build.

## MTP decision

The base metadata advertises one MTP layer, but NovaForge's pinned in-process llama C seam does not yet expose a verified draft/acceptance receipt for this architecture. MTP remains disabled. It may be enabled only when the exact target and draft artifacts, accepted-draft-token count, output equivalence/quality, peak memory, and end-to-end latency are recorded. A speedup on a different runtime or model is not admission evidence.

## Admission matrix

`Power — On-device streamed (experimental)` remains separate from `Power — Companion`; failure never sends a prompt over LAN. Physical admission on the exact iPhone 12 requires all of the following in one provenance-bound receipt:

| Gate | Required evidence |
| --- | --- |
| Artifact | Exact base/quant revisions and the selected IQ1/IQ2/Q3 byte count and SHA-256 above; no vision projector |
| Resident memory | 1.5 GB stage-window target; measured process peak below the safe device ceiling |
| Storage | Location, sequential/random MB/s, read sizes, cache controls, internal vs security-scoped external |
| Generation | Successful load, positive TTFT, exact 128 useful runtime-token events, measured decode seconds/token |
| Profiles | CPU, partial Metal, and full Metal; no assumption that the largest offload is fastest or safest |
| Quality | Pinned corpus and exact-output/tool-safety gates; IQ1_S compared with an IQ2 and a quality-preserving alternative before promotion |
| Lifecycle | Background/foreground, memory warning, unload/reload, cancellation, and lease release |
| Device health | Thermal maximum, battery before/after, no jetsam or critical thermal event |

Simulator and GitHub Xcode 27 evidence can validate parsing, routing, receipts, UI, and lifecycle fixtures. It cannot establish A14 storage speed, resident memory, thermal behavior, or model usability. Until the physical matrix passes, the UI must say `Experimental · physical benchmark pending` and show no on-device speed claim.

Run one provenance-bound matrix per quant with `POWER_VARIANT=iq1`, `POWER_VARIANT=iq2`, and `POWER_VARIANT=q3`. A candidate is admitted only by its own receipt; a pass for one quant does not admit either of the others.

## Primary references

- Apple Machine Learning Research, [LLM in a Flash](https://machinelearning.apple.com/research/efficient-large-language)
- [PowerInfer-2](https://arxiv.org/abs/2406.06282) and its [project page](https://powerinfer.ai/v2/)
- [ActiveFlow](https://arxiv.org/abs/2504.08378)
- CMU, [Deploying Large Language Models to Mobile Phones with Memory Offloading](https://www.andrew.cmu.edu/course/15-821/assets/POSTERS/2025-project-07a-poster-jin-lai.pdf)
- [AirLLM](https://github.com/lyogavin/airllm)
- [Pinned Qwen3.8-27B configuration](https://huggingface.co/Qwen/Qwen3.8-27B/blob/1d4bf0f2ff6012fd82039f2fa52739d0dd7c60c0/config.json)

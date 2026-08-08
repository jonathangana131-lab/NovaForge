# NovaForge V14 — Local AI Research Seeds

**Snapshot date:** 2026-08-08  
**Purpose:** concrete low-memory/on-device research directions for NovaForge workers to prototype and benchmark. These are research inputs, **not support claims**. Live upstream documentation and exact-device evidence outrank this snapshot.

## 1. Apple — LLM in a Flash

Source: https://machinelearning.apple.com/research/efficient-large-language

Key idea: keep model parameters in flash and bring them into DRAM on demand. Apple describes hardware-aware windowing that reuses activated neurons plus row/column bundling for larger contiguous flash reads. The paper reports running models up to roughly 2x available DRAM with large speedups over naive flash loading.

NovaForge experiment:
- prototype flash-backed cold-weight/neuron loading on iOS;
- preserve a small resident hot working set;
- benchmark memory, prefill, decode, energy, thermal and flash I/O on exact iPhone classes;
- never copy headline paper numbers into product UI without device reproduction.

## 2. PowerInfer-2 — smartphone inference beyond memory capacity

Source: https://arxiv.org/abs/2406.06282

Key idea: neuron-cluster scheduling across compute + storage, dense clusters on accelerator, sparse clusters on CPU, fine-grained I/O/computation pipelining, segmented neuron cache. The paper demonstrates a 47B model on a smartphone in its evaluated environment.

NovaForge experiment:
- study whether cluster/expert scheduling concepts can map safely to Apple CPU + Metal + flash;
- prioritize sparse/MoE architectures where not every parameter must be active per token;
- compare against ordinary mmap/quantized GGUF baselines.

## 3. Google TurboQuant (ICLR 2026)

Source: https://research.google/blog/turboquant-redefining-ai-efficiency-with-extreme-compression/

Key idea: aggressive vector/KV compression using PolarQuant + Quantized Johnson-Lindenstrauss. Google reports KV-cache memory reductions of at least ~6x in tested settings and very low-bit representations without the usual per-block quantization overhead.

NovaForge experiment:
- isolated Metal/CPU prototype for local KV compression;
- long-context coding/tool-call accuracy suite;
- measure actual iPhone memory savings and latency;
- keep as experimental until quality and runtime stability are proven.

## 4. Adaptive KV precision (2026)

Source: https://arxiv.org/abs/2604.04722

Key idea: dynamically choose 2/4/8-bit or FP16 KV precision based on token importance rather than giving every token the same memory budget.

NovaForge experiment:
- preserve system/tool/schema/current-code tokens at higher precision;
- compress low-importance historical context more aggressively;
- benchmark on coding edits, structured tool use, retrieval and long autonomous missions.

## 5. llama.cpp Metal quantized KV + mmap

Feature matrix: https://github.com/ggml-org/llama.cpp/wiki/Feature-matrix

Current llama.cpp supports model K/I quants, Metal, Flash Attention, and quantized K-cache paths. Its CLI also supports configurable K/V cache types and memory-mapped model loading.

NovaForge experiment:
- make KV quant profile a device/runtime qualification dimension;
- dynamically choose q8/q4/etc only from measured quality curves;
- compare mmap behavior vs eager resident loading under iOS memory pressure;
- never expose unsupported backend combinations as available UI choices.

## 6. WIP Metal TurboQuant community experiment

Source: https://github.com/ggml-org/llama.cpp/discussions/21243

There is community work exploring a native Apple Silicon/Metal implementation of TurboQuant-style KV compression. Treat this as a research signal, not production upstream support.

NovaForge experiment:
- inspect implementation ideas and upstream status;
- reproduce independently in an isolated benchmark branch before any app integration;
- require correctness tests and exact-device memory/performance evidence.

## 7. Microsoft BitNet / bitnet.cpp

Runtime: https://github.com/microsoft/BitNet
Paper: https://arxiv.org/abs/2504.12285

BitNet b1.58 uses native ternary/1.58-bit weights rather than only post-training quantization. Microsoft’s bitnet.cpp includes ARM CPU kernels and continues receiving optimization work.

NovaForge experiment:
- evaluate BitNet b1.58 2B-class models as tiny local planning/tool/specialist models;
- investigate task-specific coding/tool fine-tunes instead of expecting a general 2B model to solve every mission;
- profile ARM CPU vs Metal alternatives and energy/thermal behavior.

## 8. Liquid LFM2.5 — tiny edge model ladder

Collections:
- https://huggingface.co/collections/LiquidAI/lfm25
- https://huggingface.co/LiquidAI

Current research candidates include very small 230M/350M models, 1.2B instruct/thinking models, small encoders, and LFM2.5-8B-A1B (8.3B total / about 1.5B active) with GGUF support.

NovaForge experiment:
- 230M/350M: routing, classification, extraction, compacting, symbol ranking;
- tiny LFM2.5 encoders: Project Brain retrieval/prompt routing;
- 1.2B: fast agent/tool tier qualification;
- 8B-A1B: experimental deep/MoE tier, potentially paired with flash/expert streaming research;
- do not assume any of these are strong coding models until NovaForge’s own coding/tool benchmark proves it.

## 9. Qwen3.5 small-agent candidates

Example upstream model card: https://huggingface.co/Qwen/Qwen3.5-4B

Treat current small Qwen agent/multimodal models as qualification candidates, especially when exact runtime/quant support exists. Family reputation is not support evidence.

NovaForge experiment:
- structured tool calls;
- multi-file coding;
- screenshot/visual understanding;
- repair loops;
- memory/thermal behavior on exact device.

## 10. Tiny-model specialist architecture

Do not wait for one miracle model.

NovaForge should test a cooperative local stack:
- 200M–400M router/compactor/encoder;
- ~1B fast agent/tool model;
- 2B–5B code/reasoning tier when device permits;
- larger sparse/beyond-RAM tier only for hard escalations;
- deterministic runtime/test infrastructure supplies truth so the model does not need to “guess” success.

## 11. Priority experiments for iPhone 12 baseline

Run these in isolation before product promotion:

1. exact llama.cpp Metal q8/q4 KV memory curve vs context length;
2. Project Capsule + retrieval reduction in prompt tokens per autonomous stage;
3. LFM2.5 230M/350M retrieval/router latency and memory;
4. LFM2.5 1.2B agent/tool quality vs memory/thermal;
5. BitNet 2B ARM inference feasibility;
6. flash-backed weight streaming prototype;
7. sparse/MoE expert paging prototype;
8. TurboQuant/adaptive-KV Metal prototype;
9. tiny draft + larger verifier speculative decoding;
10. Full Forge end-to-end task success per joule, not only tokens/sec.

For every profile store exact:
model + revision + tokenizer + runtime + runtime revision + quant + KV type + context + device + OS + memory + thermal + speed + task-suite results.

**A compatibility badge must represent reproduced evidence, not optimism.**

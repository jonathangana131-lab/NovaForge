# ForgeCompactCore

`ForgeCompactCore` is the V14 truth/policy foundation for NovaForge's **Forge Compact** subsystem. It exists to make long local autonomous missions cheaper without allowing compression, caching, or memory pressure to erase accepted mission truth or manufacture device support.

## What this package defines

- hierarchical context tiers: always-resident mission truth, active working set, Project Brain retrieval, and cold archive;
- fail-closed token budgeting: required truth cannot be silently dropped when a budget is too small;
- explicit retrieval relevance ordering rather than choosing context by token size alone;
- versioned Project Capsules bound to project, mission, checkpoint, source revision, mission revision, accepted decisions, unresolved decisions, evidence receipts, and known defects;
- decode-time capsule revalidation so persisted bytes cannot bypass construction invariants;
- fail-closed resume authority referencing the current mission stage, Project Brain revision, accepted checkpoint receipt, mission-policy receipt, model-policy receipt, and optional Design DNA revision;
- exact stale-resume rejection across project, mission, source revision, and mission revision;
- exact prefix/KV reuse identity across model, model revision, tokenizer, runtime, runtime revision, prompt template, tool schema, and stable-prefix digest;
- evidence-gated compression/runtime techniques;
- memory-pressure policy that sheds optional cost before always-resident mission truth.

## Truth boundary

This package does **not** implement llama.cpp, Metal kernels, KV quantization, TurboQuant, speculative decoding, mmap, flash-backed weight loading, sparse expert paging, or Project Brain retrieval itself. It does not claim any model is compatible with an iPhone, any compression ratio, tokens/sec, RAM saving, thermal result, or battery result.

A research/source report may make a technique visible only as **experimental** when the caller explicitly opts into research behavior. A technique becomes `qualified` here only when the adapter supplies a successful exact-device qualification bound to exact model/revision/tokenizer/runtime/runtime revision/quant/KV/context/device/OS identity. The adapter remains responsible for proving that evidence is genuine.

Resume authority stores only opaque IDs/revisions for canonical Mission Engine, Project Brain, checkpoint, policy, model-policy, and Design DNA truth. Forge Compact does not become a second authority for those domains. Integration must resolve those references and reject missing, stale, or conflicting receipts before execution resumes.

## Current upstream research context

These are research inputs, not product support claims:

- Apple, **LLM in a Flash**: https://machinelearning.apple.com/research/efficient-large-language
- llama.cpp feature matrix: https://github.com/ggml-org/llama.cpp/wiki/Feature-matrix
- Google Research, **TurboQuant**: https://research.google/blog/turboquant-redefining-ai-efficiency-with-extreme-compression/

NovaForge must fresh-check upstream runtime support and reproduce relevant results on the exact target device before promoting any technique from research to supported product behavior. The iPhone 12 / A14 baseline requires exact-device evidence; simulator or research-paper numbers do not count as physical-device proof.

## Intended integration

Future adapters should consume canonical Mission Engine, Project Brain, Local Model Center, and local runtime authorities rather than duplicating them inside this package. Forge Compact is a compaction/reuse policy seam, not a second mission state machine or model compatibility catalog.

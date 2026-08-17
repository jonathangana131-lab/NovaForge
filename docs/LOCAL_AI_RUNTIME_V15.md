# NovaForge Local AI Runtime V15

Status: architecture + qualification contract. Nothing in this document is a physical-device performance claim unless a receipt is linked for the exact device/model/runtime head.

## Goal

Make local inference on memory-constrained iPhones reliable first, then fast. NovaForge must be able to adopt new runtimes without rewriting chat/agent code or presenting an experimental accelerator as a qualified default.

## Backend lanes

### Lane A — GGUF / llama.cpp compatibility lane

This is the broad model-compatibility backend and the current shipping foundation.

Current V15 engine baseline:
- llama.cpp b10456 official iOS XCFramework.
- GGUF weights request mmap loading by default.
- F16 K/V cache is the normal fast path.
- Flash Attention stays `automatic`; the backend may decline it.
- K/Q/V offload remains enabled unless a measured device profile overrides it.
- A single generation task owns each stream and is cancelled when the stream terminates.

Allocation ladder:
1. Requested profile: configured context/batch, F16 K/V by default.
2. Fast memory rescue: only after context allocation failure; context <= 1024, batch <= 32, still F16 K/V.
3. Deep memory rescue: only after both fast allocations fail; context <= 768, batch <= 16, Q8 K/V.

Reason: quantized K/V can save memory but can lose throughput on some Metal/device/model combinations. It is therefore a rescue mechanism until exact-device measurements prove it should be promoted for a particular profile.

### Lane B — Core ML / ANE MLKV candidate

Candidate memory-focused backend for converted models. The useful pattern is not simply "run Core ML":
- split decoder weights into independently loadable chunks;
- keep the embedding table as an mmap sidecar where the model layout permits it;
- keep one dominant K/V state per chunk in `MLState`;
- update that state in-graph with slice updates;
- keep smaller recurrent state on classic I/O when combining multiple StateTypes harms ANE execution;
- reuse hidden/RoPE/mask/position buffers;
- reduce ANE-to-Swift output transfer with an in-graph head when quality permits;
- verify actual ANE residency before reporting this as an ANE backend.

This lane must remain model-specific until conversion, output parity, memory, thermal, and exact-device receipts exist.

### Lane C — LiteRT-LM candidate

Google LiteRT-LM is a second converted-model candidate with native Swift/iOS and Metal support, speculative/MTP support, tool-oriented APIs, and broad model support.

Do not promote it merely because a benchmark is fast. iOS qualification must include address-space fragmentation and large-section mmap stress because large contiguous model sections can fail even when nominal free memory is sufficient.

### Core AI / iOS 27

Core AI is the preferred future Apple-native execution API to evaluate for supported converted models because it exposes stateful execution, zero-copy paths, specialization/cache control, and explicit Apple-silicon execution infrastructure.

A14 must be treated separately from newer Apple-Intelligence-class devices. Features that require newer hardware (for example some ahead-of-time compilation paths) cannot be used as an iPhone 12 qualification claim.

## Runtime selection policy

Do not choose a backend from marketing labels. Choose from receipts.

For every exact device + OS + model artifact + runtime commit, record:
- model artifact SHA-256 and byte count;
- runtime/version/commit;
- backend and effective allocation tier;
- effective context and batch;
- K/V type and Flash Attention mode;
- load time;
- time to first visible token;
- decode tokens/s using actual generated token IDs where available;
- peak physical footprint and available memory before load;
- thermal state before/after;
- cancellation latency;
- output/token parity or task-quality gate;
- crash / OOM / watchdog result;
- repeated cold/warm runs.

A candidate becomes the default only when it beats or materially extends the current default on the target device without failing correctness or stability gates.

## Speculative decoding policy

Speculation, MTP, n-gram drafting, or a separate tiny drafter is an optimization lane, never an assumption.

Promotion gate:
1. identical or accepted output-quality result;
2. lower end-to-end latency or higher decode throughput on the exact target device;
3. no worse peak memory beyond the device budget;
4. no thermal regression that destroys sustained throughput;
5. cancellation remains prompt and deterministic.

If any speculative mode is slower than baseline, NovaForge disables it for that device/model profile.

## iPhone 12 qualification target

The iPhone 12 lane is explicitly memory constrained. Qualification should run in this order:
1. Ultra-light model, GGUF requested/F16 path.
2. Qwen coder configured profile, GGUF requested/F16 path.
3. Forced allocation pressure to exercise fast rescue.
4. Forced allocation pressure to exercise Q8 deep rescue.
5. Core ML MLKV candidate artifact, if conversion is available for a useful coding model.
6. LiteRT-LM candidate artifact only after its iOS mmap/fragmentation gate passes.
7. Optional speculative modes last.

No UI should display "iPhone 12 proven", a measured token rate, or a measured peak-memory number until the matching physical-device receipt exists.

## Product architecture boundary

Chat, workspace, tool authority, and agent planning must not depend on a specific inference engine. The inference backend is responsible for:
- model load/unload;
- bounded streaming;
- cancellation;
- effective runtime profile reporting;
- memory/thermal admission;
- benchmark receipts.

Tool execution remains outside the model runtime. Local model output must remain schema/grammar constrained and validated before any action is executed.

## Rollout

1. Get llama.cpp b10456 migration fully green in CI.
2. Run exact-head physical iPhone 12 qualification.
3. Preserve GGUF as fallback even if a converted backend wins performance.
4. Add Core ML MLKV as a separately gated backend rather than replacing GGUF.
5. Add LiteRT-LM only when its exact iOS artifact passes fragmentation and output gates.
6. Auto-select only from stored qualification receipts; otherwise expose the candidate as experimental.

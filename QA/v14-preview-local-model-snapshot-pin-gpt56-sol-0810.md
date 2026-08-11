# V14 Preview Local Model Snapshot Pin Truth Gate

Protocol: NF-SWARM-v14  
Worker: GPT56-SOL-NF-V14-MLX-SNAPSHOT-PIN-0810  
Base: `main@991ece0ed9add9acf1108055f489b25f6cc9843f`  
Branch: `guard/GPT56-SOL-NF-V14-MLX-SNAPSHOT-PIN-0810/e1`

## Finding

The draft Nanbeige/MLX A14 backend in PR #232 pins its Swift runtime dependency graph, but the refreshed runtime at head `e3726e98eb0a36719c15e0bce8a4fc3b4225be4a` still does not pin the model snapshot itself.

The runtime currently constructs `ModelConfiguration(id: profile.repositoryID)` without an immutable Hugging Face model revision. Its new cache-only inference path also contains two mutable fallback seams: `revision ?? "main"` in the cache-only downloader and `ref: "main"` when resolving whether a profile snapshot is cached.

The cache-only network boundary is useful Local Only hardening, but offline bytes still need immutable identity. Otherwise the same NovaForge profile can refer to different model/config/tokenizer snapshots over time depending on which upstream `main` snapshot happened to be installed previously. A physical iPhone 12 qualification receipt produced from that mutable identity would not satisfy V14's exact model + revision + tokenizer + runtime requirement.

The original model-identity finding is durably recorded on PR #232 as review `4902314586`. This guard does not guess missing model revisions; those must come from a live upstream commit lookup for each exact MLX repository.

## Repair in this lane

Added a permanent fail-closed qualification gate without touching the occupied MLX runtime implementation:

- `scripts/validate_v14_local_model_snapshot_pins.py`
- `.github/workflows/v14-local-model-snapshot-pins.yml`

If `NovaForgeMLXRuntime.swift` is absent, the gate passes because there is no MLX snapshot load to qualify yet. Once the runtime exists, the Python validator requires:

1. `NovaForgeMLXProfile` declares a `revision: String` profile property;
2. every profile branch returns a literal full 40-character lowercase Git SHA;
3. the number of immutable revision literals matches the number of MLX profile enum cases;
4. profile-backed `ModelConfiguration` loads bind both `id: profile.repositoryID` and `revision: profile.revision`;
5. mutable/default model loads, branch labels such as `main`, and abbreviated SHAs fail validation.

The workflow adds a second cache-identity gate and rejects the runtime if it contains either:

- a cache revision lookup such as `ref: "main"`, `ref: "master"`, or `ref: "latest"`;
- an optional downloader revision fallback (`revision ?? ...`) instead of failing closed when no exact revision is supplied.

This deliberately chooses a narrow source shape rather than silently accepting an unprovable indirection. If the MLX integration architecture changes later, the guard should be intentionally updated with equivalent fail-closed evidence rather than weakened.

## Adversarial validation

Before GitHub persistence, the Python validator was exercised locally with stdlib-only tests covering:

- valid two-profile full-SHA pinning -> accepted;
- mutable `ModelConfiguration(id: profile.repositoryID)` -> rejected;
- `main` revision -> rejected;
- abbreviated revision -> rejected;
- repository head without the MLX runtime -> accepted without claiming qualification.

Commands:

```text
python3 -m py_compile /tmp/validate_v14_local_model_snapshot_pins.py
python3 /tmp/validate_v14_local_model_snapshot_pins.py --self-test --repo-root /tmp/nonexistent-novaforge-root
```

Result: all adversarial validator assertions passed, followed by the expected absent-runtime pass.

After PR #232 added the cache-only lane, branch workflow hardening added explicit rejection for the two newly observed mutable cache constructs. GitHub Actions now runs `py_compile`, the Python adversarial self-test, repository model-pin validation, and the cache-identity grep gate on relevant pull requests and pushes to `main`.

## Interaction with PR #232

Current `main` does not contain `NovaForgeMLXRuntime.swift`, so this truth guard can merge independently without claiming MLX readiness. When PR #232 or a successor rebases on the guard, the current runtime should fail for three independent reasons until its identity is corrected:

1. no `NovaForgeMLXProfile.revision` full-SHA mapping;
2. `ModelConfiguration` does not bind an exact revision;
3. cache lookup/downloader still admits mutable `main` fallback behavior.

The intended repaired shape is one immutable profile revision used consistently for explicit installation, cache lookup, and generation-time model configuration. Missing exact revision/cache bytes should fail closed rather than widen to a mutable branch.

## Truth boundary / non-claims

This lane proves a source/CI qualification precondition only.

It does **not** claim:

- a verified Nanbeige 3-bit or 2-bit Hugging Face commit SHA;
- successful MLX inference;
- tokenizer/tool-call correctness;
- a completed app-side model download/status lifecycle;
- iPhone 12 memory, speed, thermal, energy, cancellation, or relaunch results;
- physical-device Local Only / zero-network evidence;
- that PR #232 is user-ready.

Those remain separate Preview Local AI acceptance work. Exact physical-device qualification must bind the final immutable model revision and runtime identity that actually ran.

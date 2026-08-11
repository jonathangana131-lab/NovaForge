# V14 Preview Local Model Snapshot Pin Truth Gate

Protocol: NF-SWARM-v14  
Worker: GPT56-SOL-NF-V14-MLX-SNAPSHOT-PIN-0810  
Base: `main@991ece0ed9add9acf1108055f489b25f6cc9843f`  
Branch: `guard/GPT56-SOL-NF-V14-MLX-SNAPSHOT-PIN-0810/e1`

## Finding

The draft Nanbeige/MLX A14 backend in PR #232 pins its Swift runtime dependency graph, but its model loader currently constructs `ModelConfiguration(id: profile.repositoryID)` without an immutable Hugging Face model revision.

That means the repository ID can resolve to different model/config/tokenizer bytes later while NovaForge still presents the same profile identity. Any physical iPhone 12 qualification receipt produced from that mutable load would therefore be non-reproducible and would not satisfy V14's exact model + revision + tokenizer + runtime identity requirement.

The finding is durably recorded on PR #232 as review `4902314586`. This guard does not guess the missing model revisions; those must come from a live upstream commit lookup for each exact MLX repository.

## Repair in this lane

Added a permanent fail-closed source contract:

- `scripts/validate_v14_local_model_snapshot_pins.py`
- `.github/workflows/v14-local-model-snapshot-pins.yml`

The validator deliberately does not touch the occupied MLX runtime implementation. Instead it makes the repository enforce the qualification precondition when that runtime lands.

If `NovaForgeMLXRuntime.swift` is absent, the guard passes because there is no MLX snapshot load to qualify yet. Once the runtime exists, the guard requires:

1. `NovaForgeMLXProfile` declares a `revision: String` profile property;
2. every profile branch returns a literal full 40-character lowercase Git SHA;
3. the number of immutable revision literals matches the number of MLX profile enum cases;
4. profile-backed `ModelConfiguration` loads bind both `id: profile.repositoryID` and `revision: profile.revision`;
5. mutable/default loads, branch labels such as `main`, and abbreviated SHAs fail validation.

This deliberately chooses a narrow source shape rather than silently accepting an unprovable indirection. If the MLX integration architecture changes later, the guard should be intentionally updated with equivalent fail-closed evidence rather than weakened.

## Adversarial validation

The validator has a built-in stdlib-only self-test covering:

- valid two-profile full-SHA pinning -> accepted;
- mutable `ModelConfiguration(id: profile.repositoryID)` -> rejected;
- `main` revision -> rejected;
- abbreviated revision -> rejected;
- repository head without the MLX runtime -> accepted without claiming qualification.

Before GitHub persistence, the exact validator text was exercised locally with:

```text
python3 -m py_compile /tmp/validate_v14_local_model_snapshot_pins.py
python3 /tmp/validate_v14_local_model_snapshot_pins.py --self-test --repo-root /tmp/nonexistent-novaforge-root
```

Result: all four adversarial self-test assertions passed, followed by the expected absent-runtime pass.

The durable GitHub workflow repeats `py_compile`, the adversarial self-test, and repository validation on relevant pull requests and pushes to `main`.

## Interaction with PR #232

Current `main` does not contain `NovaForgeMLXRuntime.swift`, so this guard can merge independently without claiming MLX readiness. When PR #232 or a successor is rebased on the guard, the current mutable model load should fail until exact immutable model revisions are added and wired into `ModelConfiguration`.

This is intentional. A green runtime build is not enough to promote an A14 local model when the model snapshot itself can drift.

## Truth boundary / non-claims

This lane proves a source/CI qualification precondition only.

It does **not** claim:

- a verified Nanbeige 3-bit or 2-bit Hugging Face commit SHA;
- successful MLX inference;
- tokenizer/tool-call correctness;
- a completed model download/cache lifecycle;
- iPhone 12 memory, speed, thermal, energy, cancellation, or relaunch results;
- physical-device Local Only / zero-network evidence;
- that PR #232 is user-ready.

Those remain separate Preview Local AI acceptance work. Exact physical-device qualification must bind the final immutable model revision and runtime identity that actually ran.

# V14 Forge Runtime acceptance fixtures

This directory contains two representative generated-project fixtures for NovaForge V14 integration work:

- `focus-notes/`: a small local-only utility.
- `vector-drift/`: a small local-only 2D game.

These are untrusted test assets. They do not grant runtime, playtest, visual, device, or completion authority.

## Structural validation

Run from the repository root:

```sh
python3 scripts/validate-v14-forge-runtime-fixtures.py
python3 -m unittest -v scripts/tests/test_validate_v14_forge_runtime_fixtures.py
python3 -m unittest -v scripts/tests/test_v14_forge_runtime_vector_drift_geometry.py
scripts/validate-v14-forge-runtime-fixtures-swift.sh
```

The Python validator intentionally fails closed on unknown fixture directories, unexpected files inside a fixture, cross-project storage namespaces, external-network primitives/references, hidden resource-loading references, duplicate semantic target IDs, and contract drift in the expected semantic target set.

The Vector Drift geometry regression test parses the fixture's actual rover, beacon, barrier, and canvas constants, then runs a collision-aware 6 px grid search using the same circle-versus-rectangle collision rule. It requires all three collect targets to remain reachable from spawn.

The Swift validation script compiles the repository's actual `ForgeRuntimeManifest`, `ForgeRuntimeManifestValidator`, and `ForgeRuntimeLaunchAuthorization` sources with a temporary harness, then requires both fixture manifests to decode and be launchable under the default host support snapshot. It does not modify RuntimeKit or grant runtime authority.

## Worker evidence — 2026-08-10

On branch `agent/v14-generated-runtime-acceptance-fixtures`:

- structural validator: PASS for both fixtures;
- adversarial Python validator tests: PASS, 7/7;
- Vector Drift goal-reachability regression: PASS, 1/1;
- `python3 -m py_compile` for validator/tests: PASS;
- inline JavaScript extracted from both fixtures and checked with `node --check`: PASS, 2/2;
- current RuntimeKit manifest decoder + validator logic: PASS for both manifests, zero warnings;
- repeatable Swift validator script syntax/end-to-end harness check: PASS in the worker environment using the current extracted RuntimeKit source logic; in a normal repository checkout the script compiles those three RuntimeKit files directly;
- active semantic-input bridge review: `novaforge:action` carries `detail.value` and `novaforge:gesture` carries `detail.gestureID`, matching Vector Drift listeners;
- collision-aware 6 px grid reachability scan: all three Vector Drift beacon targets are reachable from spawn in the current obstacle geometry;
- remote Git blob identity was checked against the locally tested bytes for both manifests, both HTML files, Python validator, and Python validator tests.

Headless Chromium screenshot attempts timed out in the worker environment because the browser could not establish expected system services. Therefore there is **no** screenshot/visual acceptance evidence from this pass.

## Truth boundary

Passing these fixture validators proves only the checked source/structure, geometry, and manifest-acceptance invariants. It does not prove a real ForgeRuntime launch, autonomous self-play completion, screenshot quality, accessibility instrumentation, simulator/physical-device behavior, performance, thermal behavior, or Completion Constitution acceptance. Those require their own receipts from the relevant NovaForge authorities.

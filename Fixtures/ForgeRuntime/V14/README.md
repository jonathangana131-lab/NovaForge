# V14 Forge Runtime acceptance fixtures

This directory contains two representative generated-project fixtures for NovaForge V14 integration work:

- `focus-notes/`: a small local-only utility.
- `vector-drift/`: a small local-only 2D game.

These are untrusted test assets. They do not grant runtime, playtest, visual, device, or completion authority.

## Structural validation

Run from the repository root:

```sh
python3 scripts/validate-v14-forge-runtime-fixtures.py
python3 -m unittest -v scripts/tests/test_validate_v14_forge-runtime-fixtures.py
```

The validator intentionally fails closed on unknown fixture directories, unexpected files inside a fixture, cross-project storage namespaces, external-network primitives/references, hidden resource-loading references, duplicate semantic target IDs, and contract drift in the expected semantic target set.

## Worker evidence — 2026-08-10

On branch `agent/v14-generated-runtime-acceptance-fixtures`:

- structural validator: PASS for both fixtures;
- adversarial Python tests: PASS, 7/7;
- `python3 -m py_compile` for validator/tests: PASS;
- inline JavaScript extracted from both fixtures and checked with `node --check`: PASS, 2/2;
- active semantic-input bridge review: `novaforge:action` carries `detail.value` and `novaforge:gesture` carries `detail.gestureID`, matching Vector Drift listeners;
- collision-aware 6 px grid reachability scan: all three Vector Drift beacon targets are reachable from spawn in the current obstacle geometry;
- remote Git blob identity was checked against the locally tested bytes for both manifests, both HTML files, validator, and tests.

Headless Chromium screenshot attempts timed out in the worker environment because the browser could not establish expected system services. Therefore there is **no** screenshot/visual acceptance evidence from this pass.

## Truth boundary

Passing this fixture validator proves only the checked source/structure invariants. It does not prove a real ForgeRuntime launch, autonomous self-play completion, screenshot quality, accessibility instrumentation, simulator/physical-device behavior, performance, thermal behavior, or Completion Constitution acceptance. Those require their own receipts from the relevant NovaForge authorities.

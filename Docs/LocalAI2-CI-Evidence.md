# Local AI 2.0 CI evidence boundary

The explicit `xcode-27` hosted lane is intentionally limited to source,
package, simulator, and generic-device evidence. A simulator test or an
unsigned generic iOS build
cannot establish physical-device behavior, Core AI execution, throughput,
memory, thermal, battery, or a model-default claim.

Each CI lane writes to a run-specific directory and emits
`evidence-manifest.json` plus `evidence-manifest.sha256`. The manifest binds
the source commit/tree, the discovered build products, raw log/screenshot
files, and their SHA-256 hashes. CI manifests set `claimsAllowed: false`.

Physical/Core AI release admission is separate and fail-closed:

```sh
scripts/validate-local-ai-receipts.py \
  --physical-receipt /absolute/path/physical.json \
  --coreai-receipt /absolute/path/coreai.json
```

Both files are required schema-v2 receipts with `executionClass: physical`,
verified availability, matching run/source/app identities, physical device
flags, artifact hashes, and corpus hashes. Missing, simulator, generic-build,
partial, or unavailable receipts return a non-zero status and cannot be
reported as success. The final acceptance report must preserve that boundary.

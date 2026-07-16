#!/bin/bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "$0")/.." && pwd)
SCORECARD="$ROOT_DIR/scripts/codex-m5-scorecard.py"
TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/novaforge-m5-scorecard.XXXXXX")
trap 'rm -rf "$TMP_DIR"' EXIT

make_fixture() {
  local destination="$1"
  local v2_total="$2"
  local include_forbidden="$3"
  /usr/bin/python3 - "$destination" "$v2_total" "$include_forbidden" <<'PY'
import json
import sys

destination, v2_total, include_forbidden = sys.argv[1], float(sys.argv[2]), sys.argv[3] == "yes"
digest = "sha256:" + "a" * 64
workspace = "sha256:" + "b" * 64
samples = []
for index in range(100):
    pair = f"pair-{index:03d}"
    for engine in ("v1", "v2"):
        sample = {
            "pairID": pair,
            "engine": engine,
            "success": True,
            "acceptanceMs": 80 if engine == "v1" else 90,
            "ttftMs": 500 if engine == "v1" else 540,
            "totalMs": 1000 if engine == "v1" else v2_total,
            "contextSHA256": digest,
            "transcriptSHA256": digest,
            "evidenceSHA256": digest,
            "workspaceBeforeSHA256": workspace,
            "workspaceAfterSHA256": workspace,
            "errorCategory": None,
        }
        if include_forbidden and index == 0 and engine == "v2":
            sample["prompt"] = "this content field must be rejected"
        samples.append(sample)
payload = {
    "schemaVersion": 1,
    "route": {
        "provider": "openai",
        "model": "gpt-test",
        "temperature": 0.0,
        "maxOutputTokens": 4096,
        "sampleTarget": 100,
    },
    "samples": samples,
}
with open(destination, "w", encoding="utf-8") as handle:
    json.dump(payload, handle)
PY
}

make_fixture "$TMP_DIR/pass.json" 1080 no
"$SCORECARD" "$TMP_DIR/pass.json" --output "$TMP_DIR/pass-scorecard.json"
grep -q '"status": "pass"' "$TMP_DIR/pass-scorecard.json"

/usr/bin/python3 - "$TMP_DIR/pass.json" "$TMP_DIR" <<'PY'
import copy
import json
import os
import sys

source, destination = sys.argv[1:]
with open(source, encoding="utf-8") as handle:
    baseline = json.load(handle)

variants = {}
parity = copy.deepcopy(baseline)
parity["samples"][1]["contextSHA256"] = "sha256:" + "c" * 64
variants["parity"] = parity

workspace = copy.deepcopy(baseline)
workspace["samples"][1]["workspaceAfterSHA256"] = "sha256:" + "d" * 64
variants["workspace"] = workspace

acceptance = copy.deepcopy(baseline)
for sample in acceptance["samples"]:
    if sample["engine"] == "v2":
        sample["acceptanceMs"] = 201
variants["acceptance"] = acceptance

unpaired = copy.deepcopy(baseline)
unpaired["samples"] = [
    sample for sample in unpaired["samples"]
    if not (sample["pairID"] == "pair-099" and sample["engine"] == "v2")
]
variants["unpaired"] = unpaired

malformed = copy.deepcopy(baseline)
malformed["samples"][0]["evidenceSHA256"] = "not-a-digest"
variants["malformed"] = malformed

for name, payload in variants.items():
    with open(os.path.join(destination, name + ".json"), "w", encoding="utf-8") as handle:
        json.dump(payload, handle)
PY

for name in parity workspace acceptance; do
  set +e
  "$SCORECARD" "$TMP_DIR/$name.json" --output "$TMP_DIR/$name-scorecard.json"
  status=$?
  set -e
  [ "$status" -eq 1 ]
done
grep -q '"exactContextTranscriptEvidenceParity": false' "$TMP_DIR/parity-scorecard.json"
grep -q '"readOnlyWorkspaceUnchanged": false' "$TMP_DIR/workspace-scorecard.json"
grep -q '"v2AcceptanceP95AtMost200Ms": false' "$TMP_DIR/acceptance-scorecard.json"

for name in unpaired malformed; do
  set +e
  "$SCORECARD" "$TMP_DIR/$name.json" >"$TMP_DIR/$name.out" 2>"$TMP_DIR/$name.err"
  status=$?
  set -e
  [ "$status" -eq 2 ]
done
grep -q 'unpaired sample identities' "$TMP_DIR/unpaired.err"
grep -q 'must be a lowercase sha256 digest' "$TMP_DIR/malformed.err"

make_fixture "$TMP_DIR/slow.json" 1200 no
set +e
"$SCORECARD" "$TMP_DIR/slow.json" --output "$TMP_DIR/slow-scorecard.json"
status=$?
set -e
[ "$status" -eq 1 ]
grep -q '"v2TotalP95WithinTenPercent": false' "$TMP_DIR/slow-scorecard.json"

make_fixture "$TMP_DIR/sensitive.json" 1080 yes
set +e
"$SCORECARD" "$TMP_DIR/sensitive.json" >"$TMP_DIR/sensitive.out" 2>"$TMP_DIR/sensitive.err"
status=$?
set -e
[ "$status" -eq 2 ]
grep -q 'forbidden or unknown fields' "$TMP_DIR/sensitive.err"

/usr/bin/python3 - "$TMP_DIR/pass.json" "$TMP_DIR/zero-baseline.json" <<'PY'
import json
import sys

source, destination = sys.argv[1:]
with open(source, encoding="utf-8") as handle:
    payload = json.load(handle)
for sample in payload["samples"]:
    if sample["engine"] == "v1":
        sample["ttftMs"] = 0
        sample["totalMs"] = 0
with open(destination, "w", encoding="utf-8") as handle:
    json.dump(payload, handle)
PY
set +e
"$SCORECARD" "$TMP_DIR/zero-baseline.json" --output "$TMP_DIR/zero-scorecard.json"
status=$?
set -e
[ "$status" -eq 1 ]
grep -q '"v2ToV1TTFTP95": null' "$TMP_DIR/zero-scorecard.json"
grep -q '"v2TTFTP95WithinTenPercent": false' "$TMP_DIR/zero-scorecard.json"

set +e
"$SCORECARD" "$TMP_DIR/pass.json" --output "$TMP_DIR/missing/output.json" \
  >"$TMP_DIR/output-failure.out" 2>"$TMP_DIR/output-failure.err"
status=$?
set -e
[ "$status" -eq 2 ]
grep -q '^M5 scorecard output failed:' "$TMP_DIR/output-failure.err"

echo "PASS: M5 scorecard enforces paired parity, read-only hashes, latency SLOs, and content-free schema."

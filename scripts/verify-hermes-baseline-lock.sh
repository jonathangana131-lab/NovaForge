#!/bin/bash

set -euo pipefail

ROOT_DIR=$(cd "$(dirname "$0")/.." && pwd)
FIXTURE_DIR="$ROOT_DIR/AgentPadTests/Fixtures/AgentHarnessBenchmark"

cd "$FIXTURE_DIR"
shasum -a 256 -c SHA256SUMS

/usr/bin/python3 - "$FIXTURE_DIR/hermes-baseline-lock.json" "$FIXTURE_DIR/corpus-v1.json" <<'PY'
import json
import sys
from collections import Counter
from pathlib import Path

lock = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
corpus = json.loads(Path(sys.argv[2]).read_text(encoding="utf-8"))

expected_tag = "v2026.6.5"
expected_commit = "3c231eb3979ab9c57d5cd6d02f1d577a3b718b43"
expected_image_digest = "sha256:9ad3b04ec916ea2c2da22358fd43b024c788d74073210695af88bfc2e63869b4"

assert lock["upstream"]["tag"] == expected_tag
assert lock["upstream"]["commitSHA"] == expected_commit
assert lock["container"]["indexDigest"] == expected_image_digest
assert lock["parityRun"]["corpusID"] == "novaforge-hermes-60-v1"
assert lock["parityRun"]["repetitionsPerTask"] == 3
assert lock["parityRun"]["fallbackRoutesEnabled"] is False

assert corpus["corpusID"] == lock["parityRun"]["corpusID"]
assert corpus["lockedAgainst"]["hermesTag"] == expected_tag
assert corpus["lockedAgainst"]["hermesCommit"] == expected_commit
assert corpus["repetitionsPerTask"] == 3

tasks = corpus["tasks"]
ids = [task["id"] for task in tasks]
categories = Counter(task["category"] for task in tasks)
assert len(tasks) == 60, len(tasks)
assert len(set(ids)) == 60
assert len(categories) == 12, categories
assert set(categories.values()) == {5}, categories

required_fields = {"id", "category", "title", "fixture", "prompt", "checks", "forbidden"}
for task in tasks:
    assert required_fields <= task.keys(), task.get("id")
    assert task["prompt"].strip()
    assert len(task["checks"]) >= 3
    assert len(task["forbidden"]) >= 3

print("Hermes baseline lock and 60-task parity corpus verified.")
PY

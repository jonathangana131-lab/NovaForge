#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
settings="$repo_root/AgentPad/Views/SettingsComponents.swift"

fail() {
  printf 'Local Settings truth contract failed: %s\n' "$1" >&2
  exit 1
}

[[ -f "$settings" ]] || fail "missing SettingsComponents.swift"

python3 - "$settings" <<'PY'
from pathlib import Path
import sys

source = Path(sys.argv[1]).read_text(encoding="utf-8")

for forbidden in (
    'Built to survive iPhone memory pressure',
    'Device proven',
    'physical-device canary proven',
    'The proven iPhone 12 default',
):
    if forbidden in source:
        raise SystemExit(f"unproven Local AI presentation claim remains: {forbidden}")

required = (
    'Guarded for iPhone memory pressure',
    'One GGUF runtime at a time. First load is refused when live memory or thermal headroom is unsafe.',
    'localModelSafetyCard',
)
for needle in required:
    if needle not in source:
        raise SystemExit(f"missing Local Settings safety/truth contract: {needle}")

print('Local Settings truth contract passed: memory-pressure behavior is described as a guard, not device proof')
PY

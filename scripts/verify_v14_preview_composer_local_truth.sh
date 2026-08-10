#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
composer="$repo_root/AgentPad/Views/ChatComposer.swift"
local_runtime="$repo_root/AgentPad/Services/LocalModelRuntime.swift"

for path in "$composer" "$local_runtime"; do
  [[ -f "$path" ]] || { echo "Preview Composer local truth: missing ${path#$repo_root/}" >&2; exit 1; }
done

python3 - "$composer" "$local_runtime" <<'PY'
from pathlib import Path
import sys

composer = Path(sys.argv[1]).read_text()
local_runtime = Path(sys.argv[2]).read_text()

for forbidden in (
    'iPhone 12 safe',
    'Recommended for iPhone 12',
):
    if forbidden in composer:
        raise SystemExit(
            f'Preview Composer local truth: unsupported positive device claim returned: {forbidden}'
        )

required_composer = (
    'return "On-device profile · \\(localModels.status.title)"',
    '? "Default local profile · qualification pending"',
)
for needle in required_composer:
    if needle not in composer:
        raise SystemExit(
            f'Preview Composer local truth: missing qualification-pending presentation: {needle}'
        )

# The current configured default is intentionally not qualification authority. Keep the
# presentation fail-closed while the catalog itself says exact-device qualification is pending.
if 'isIPhone12SafeDefault: true' in local_runtime:
    pending_markers = (
        'exact-device qualification pending',
        'exact-device qualification remains pending',
    )
    if not any(marker in local_runtime for marker in pending_markers):
        raise SystemExit(
            'Preview Composer local truth: configured iPhone default exists without pending exact-device qualification copy'
        )

print('Preview Composer local truth: configured local profile is not presented as iPhone 12 proof')
PY

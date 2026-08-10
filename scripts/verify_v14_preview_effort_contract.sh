#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
composer="$repo_root/AgentPad/Views/ChatComposer.swift"
fresh_run="$repo_root/AgentPad/Services/AgentSystemFreshRunRequestFactory.swift"

fail() {
  printf 'Preview effort contract failed: %s\n' "$1" >&2
  exit 1
}

[[ -f "$composer" ]] || fail "missing ChatComposer.swift"
[[ -f "$fresh_run" ]] || fail "missing AgentSystemFreshRunRequestFactory.swift"

python3 - "$composer" "$fresh_run" <<'PY'
from pathlib import Path
import sys

composer = Path(sys.argv[1]).read_text()
fresh_run = Path(sys.argv[2]).read_text()

required_composer = [
    'case .low: "Low"',
    'case .medium: "Medium"',
    'case .high: "High"',
    'case .extraHigh: "Extra High"',
    'case .ultraCode: "Ultra"',
    'preferences.reasoningEffort = .max',
    'preferences.orchestrationMode = .ultraCode',
    '.accessibilityAdjustableAction',
]
for needle in required_composer:
    if needle not in composer:
        raise SystemExit(f"missing composer contract: {needle}")

if '"UltraCode"' in composer:
    raise SystemExit('developer-facing UltraCode leaked into Composer user-facing copy')

required_runtime = [
    'preferences.effectiveReasoningEffort(',
    'case .ultraCode: ["v2UltraCodeOrchestration", "v2IsolatedAgentWorkspaces"]',
]
for needle in required_runtime:
    if needle not in fresh_run:
        raise SystemExit(f"missing runtime contract: {needle}")

print('Preview effort contract: Low / Medium / High / Extra High / Ultra -> real strongest orchestration path')
PY

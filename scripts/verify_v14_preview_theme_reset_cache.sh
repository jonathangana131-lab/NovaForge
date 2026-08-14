#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
app="$repo_root/AgentPad/App/AgentPadApp.swift"
theme="$repo_root/AgentPad/Design/AgentTheme.swift"

[[ -f "$app" ]] || { echo "missing AgentPadApp.swift" >&2; exit 1; }
[[ -f "$theme" ]] || { echo "missing AgentTheme.swift" >&2; exit 1; }

python3 - "$app" "$theme" <<'PY'
from pathlib import Path
import sys

app = Path(sys.argv[1]).read_text()
theme = Path(sys.argv[2]).read_text()

reset_marker = 'if arguments.contains("--reset-ui") {'
start = app.find(reset_marker)
if start < 0:
    raise SystemExit('missing --reset-ui launch fixture')
end = app.find('\n        }\n        #endif', start)
if end < 0:
    raise SystemExit('could not isolate --reset-ui fixture')
reset = app[start:end]

required = [
    'UserDefaults.standard.set(AgentTheme.defaultTheme.rawValue, forKey: AgentTheme.storageKey)',
    'let resetLaunchTheme = AgentTheme.resolvedForLaunch(',
    'storedRawValue: AgentTheme.defaultTheme.rawValue',
    'arguments: arguments',
    'AgentPalette.refreshThemeCache(resetLaunchTheme)',
    'AgentThemeUIKit.apply(resetLaunchTheme)',
]
for needle in required:
    if needle not in reset:
        raise SystemExit(f'missing reset-theme determinism contract: {needle}')

if 'UserDefaults.standard.set(launchTheme.rawValue, forKey: AgentTheme.storageKey)' in reset:
    raise SystemExit('reset launch override must remain ephemeral')
if 'AgentPalette.refreshThemeCache(AgentTheme.current)' in reset:
    raise SystemExit('reset fixture may not refresh AgentPalette from stale cached current theme')
if 'static func resolvedForLaunch(' not in theme:
    raise SystemExit('missing active launch-theme resolver')
if 'launchOverride(from: arguments) ?? resolved(from: storedRawValue)' not in theme:
    raise SystemExit('launch resolver must give explicit override precedence without persistence')

print('Preview theme reset cache contract: stored default + ephemeral override -> resolved launch theme -> palette/UIKit')
PY
